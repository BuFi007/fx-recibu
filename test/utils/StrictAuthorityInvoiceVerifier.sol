// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBUFIIdentityRegistry} from "../../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../../src/interfaces/IBUFIReputationRegistry.sol";
import {IAuthorityInvoiceVerifier} from "../../src/interfaces/IAuthorityInvoiceVerifier.sol";
import {WorkspaceTierRegistry} from "../../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {ReceivableCommitment} from "../../src/libraries/ReceivableCommitment.sol";

/// @notice Deterministic, stateful test double. It is deliberately mutable so
///         shelf tests can prove that runtime codehash alone is not a policy.
contract StrictAuthorityInvoiceVerifier is IAuthorityInvoiceVerifier {
    uint16 public supportedSchemaVersion;
    bytes32 public verifierConfigId;
    uint256 public approvedChainId;
    address public approvedShelf;

    mapping(bytes32 approvalKey => bool) public approved;
    mapping(bytes32 authorityInvoiceId => bool) public revoked;

    error WrongShelfCaller(address received, address expected);

    constructor(uint16 schemaVersion, bytes32 configId, uint256 chainId, address shelf) {
        supportedSchemaVersion = schemaVersion;
        verifierConfigId = configId;
        approvedChainId = chainId;
        approvedShelf = shelf;
    }

    function setSupportedSchemaVersion(uint16 value) external {
        supportedSchemaVersion = value;
    }

    function setVerifierConfigId(bytes32 value) external {
        verifierConfigId = value;
    }

    function setApprovedChainId(uint256 value) external {
        approvedChainId = value;
    }

    function setApprovedShelf(address value) external {
        approvedShelf = value;
    }

    function setRevoked(bytes32 authorityInvoiceId, bool value) external {
        revoked[authorityInvoiceId] = value;
    }

    function setApproval(
        ReceivableCommitment.AuthorityRef calldata authority,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        bool recourse,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        bool value
    ) external {
        approved[
            approvalKey(
                authority,
                sellerAgentId,
                debtorAgentId,
                currency,
                faceAmount,
                recourse,
                nInstallments,
                firstMaturity,
                interval
            )
        ] = value;
    }

    function isVerified(
        ReceivableCommitment.AuthorityRef calldata authority,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        bool recourse,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) external view returns (bool) {
        if (msg.sender != approvedShelf) revert WrongShelfCaller(msg.sender, approvedShelf);
        return !revoked[authority.authorityInvoiceId]
            && approved[
                approvalKey(
                authority,
                sellerAgentId,
                debtorAgentId,
                currency,
                faceAmount,
                recourse,
                nInstallments,
                firstMaturity,
                interval
            )
            ];
    }

    function approvalKey(
        ReceivableCommitment.AuthorityRef memory authority,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        bool recourse,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                authority,
                sellerAgentId,
                debtorAgentId,
                currency,
                faceAmount,
                recourse,
                nInstallments,
                firstMaturity,
                interval
            )
        );
    }
}

contract StrictVerifierFactory {
    function deploy(uint16 schemaVersion, bytes32 configId, uint256 chainId, address shelf)
        external
        returns (StrictAuthorityInvoiceVerifier verifier)
    {
        verifier = new StrictAuthorityInvoiceVerifier(schemaVersion, configId, chainId, shelf);
    }
}

/// @notice Shared test-only construction recipe for the verifier-first,
///         CREATE2-bound shelf fixture required by local conformance.
abstract contract StrictAuthorityFixture is Test {
    bytes32 internal constant TEST_VERIFIER_CONFIG_ID = keccak256("BUFI_STRICT_AUTHORITY_FIXTURE_V1");

    uint256 private _shelfFixtureCounter;
    uint256 private _authorityFixtureCounter;

    function _deployStrictShelf(
        IERC20 usdc,
        IBUFIIdentityRegistry identity,
        IBUFIReputationRegistry reputation,
        WorkspaceTierRegistry tiers,
        address admin
    ) internal returns (InvoiceShelf shelf, StrictAuthorityInvoiceVerifier verifier) {
        bytes32 verifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        bytes32 salt;
        address predictedShelf;
        (verifier, salt, predictedShelf) = _prepareStrictShelfFixture(
            usdc,
            identity,
            reputation,
            tiers,
            admin,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash
        );

        shelf = new InvoiceShelf{salt: salt}(
            usdc,
            identity,
            reputation,
            tiers,
            verifier,
            ReceivableCommitment.VERSION,
            TEST_VERIFIER_CONFIG_ID,
            block.chainid,
            verifierCodehash,
            admin
        );
        assertEq(address(shelf), predictedShelf, "shelf CREATE2 prediction mismatch");
    }

    function _prepareStrictShelfFixture(
        IERC20 usdc,
        IBUFIIdentityRegistry identity,
        IBUFIReputationRegistry reputation,
        WorkspaceTierRegistry tiers,
        address admin,
        uint16 verifierSchema,
        bytes32 verifierConfig,
        uint256 verifierChain,
        uint16 shelfSchema,
        bytes32 shelfConfig,
        uint256 shelfChain,
        bytes32 shelfCodehash
    ) internal returns (StrictAuthorityInvoiceVerifier verifier, bytes32 salt, address predictedShelf) {
        StrictVerifierFactory factory = new StrictVerifierFactory();
        address predictedVerifier = vm.computeCreateAddress(address(factory), 1);
        bytes32 verifierCodehash = keccak256(type(StrictAuthorityInvoiceVerifier).runtimeCode);
        salt = keccak256(abi.encode("BUFI_TEST_AUTHORITY_SHELF_FIXTURE_V1", address(this), ++_shelfFixtureCounter));
        bytes32 shelfInitCodeHash = keccak256(
            abi.encodePacked(
                type(InvoiceShelf).creationCode,
                abi.encode(
                    usdc,
                    identity,
                    reputation,
                    tiers,
                    IAuthorityInvoiceVerifier(predictedVerifier),
                    shelfSchema,
                    shelfConfig,
                    shelfChain,
                    shelfCodehash,
                    admin
                )
            )
        );
        predictedShelf = vm.computeCreate2Address(salt, shelfInitCodeHash, address(this));

        verifier = factory.deploy(verifierSchema, verifierConfig, verifierChain, predictedShelf);
        assertEq(address(verifier), predictedVerifier, "strict verifier CREATE nonce must be one");
        assertEq(address(verifier).codehash, verifierCodehash, "strict verifier runtime codehash mismatch");
    }

    function _nextAuthorityInvoiceId() internal returns (bytes32) {
        return keccak256(abi.encode("BUFI_TEST_OPAQUE_AUTHORITY_FIXTURE_V1", address(this), ++_authorityFixtureCounter));
    }

    function _fundingTerms(bytes32 authorityInvoiceId)
        internal
        view
        returns (ReceivableCommitment.FundingTerms memory)
    {
        uint64 issuedAt = uint64(block.timestamp);
        if (issuedAt == 0) issuedAt = 1;
        return ReceivableCommitment.FundingTerms({
            authority: ReceivableCommitment.AuthorityRef({
                schemaVersion: ReceivableCommitment.VERSION,
                authorityInvoiceId: authorityInvoiceId,
                authorityEvidenceCommitment: keccak256(
                    abi.encode("BUFI_TEST_AUTHORITY_EVIDENCE_V1", authorityInvoiceId)
                ),
                verifierConfigId: TEST_VERIFIER_CONFIG_ID,
                authorityVoucherType: 19,
                issuedAt: issuedAt,
                authorityPaymentDueAt: issuedAt + 90 days
            }),
            recourse: true
        });
    }

    function _approveFunding(
        StrictAuthorityInvoiceVerifier verifier,
        ReceivableCommitment.FundingTerms memory terms,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) internal {
        verifier.setApproval(
            terms.authority,
            sellerAgentId,
            debtorAgentId,
            currency,
            faceAmount,
            terms.recourse,
            nInstallments,
            firstMaturity,
            interval,
            true
        );
    }

    function _newApprovedTerms(
        StrictAuthorityInvoiceVerifier verifier,
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        address currency,
        uint128 faceAmount,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval
    ) internal returns (ReceivableCommitment.FundingTerms memory terms) {
        terms = _fundingTerms(_nextAuthorityInvoiceId());
        _approveFunding(
            verifier, terms, sellerAgentId, debtorAgentId, currency, faceAmount, nInstallments, firstMaturity, interval
        );
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ReceivableCommitment} from "../libraries/ReceivableCommitment.sol";

/// @title IAuthorityInvoiceVerifier — fail-closed authority proof boundary
interface IAuthorityInvoiceVerifier {
    function verifierConfigId() external view returns (bytes32);
    function supportedSchemaVersion() external view returns (uint16);
    function approvedChainId() external view returns (uint256);
    function approvedShelf() external view returns (address);

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
    ) external view returns (bool);
}

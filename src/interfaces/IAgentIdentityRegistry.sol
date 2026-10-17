// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IAgentIdentityRegistry — the one view DocumentReceivableRegistry needs from an identity registry
/// @notice Satisfied by both identity registries BUFI workspaces live on:
///         - the ERC-8004 IdentityRegistry (ERC-721: `ownerOf` REVERTS for an unknown id), and
///         - fx-recibu's BUFIIdentityRegistry (`ownerOf` returns address(0) for an unknown id).
///         Callers must therefore treat a revert, empty/malformed return data and address(0) all
///         as "agent does not exist". DocumentReceivableRegistry does this with a raw staticcall.
interface IAgentIdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IBUFIIdentityRegistry — workspace ↔ agentId identity + KYB flag (ERC-8004-inspired, clean-room)
interface IBUFIIdentityRegistry {
    event WorkspaceRegistered(uint256 indexed agentId, bytes32 indexed workspaceId, address owner);
    event KybStatusSet(uint256 indexed agentId, bool approved);
    event WorkspaceOwnerSet(uint256 indexed agentId, address owner);

    function registerWorkspace(bytes32 workspaceId, address owner_) external returns (uint256 agentId);
    function setKybStatus(uint256 agentId, bool approved) external;
    function setWorkspaceOwner(uint256 agentId, address newOwner) external;

    function agentIdOf(bytes32 workspaceId) external view returns (uint256);
    function workspaceOf(uint256 agentId) external view returns (bytes32);
    function ownerOf(uint256 agentId) external view returns (address);
    function kybApproved(uint256 agentId) external view returns (bool);
    function exists(uint256 agentId) external view returns (bool);
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";

/// @title BUFIIdentityRegistry
/// @notice Workspace identity on Arc — the ecosystem's FIRST identity write path
///         (GATEMAN A1: the old desk-v1 ERC-8004 write path died with the deprecated
///         package; ethereum-family 8004 registries are read-side mirrors only).
///         ERC-8004-inspired, clean-room implementation (see LICENSE_BOUNDARIES.md).
///
///  desk-v1 KYB pipeline (Persona/Alfred, alfred_teams.kyb_status)
///        │  ISSUER_ROLE (BUAttestation / ops service)
///        ▼
///  registerWorkspace(workspaceId, owner) ──▶ agentId (auto-increment, never reused)
///  setKybStatus(agentId, approved)       ──▶ the v2v hard gate (SPEC §1)
///        │
///        ▼ read by WorkspaceTierRegistry.eligible() + InvoiceShelf.lockInvoice
contract BUFIIdentityRegistry is AccessControl, IBUFIIdentityRegistry {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    uint256 internal _nextAgentId = 1; // 0 = unregistered sentinel

    mapping(bytes32 => uint256) internal _agentIdOf;
    mapping(uint256 => bytes32) internal _workspaceOf;
    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => bool) internal _kybApproved;

    error AlreadyRegistered(bytes32 workspaceId);
    error UnknownAgent(uint256 agentId);
    error ZeroAddress();
    error ZeroWorkspaceId();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerWorkspace(bytes32 workspaceId, address owner_)
        external
        onlyRole(ISSUER_ROLE)
        returns (uint256 agentId)
    {
        if (workspaceId == bytes32(0)) revert ZeroWorkspaceId();
        if (owner_ == address(0)) revert ZeroAddress();
        if (_agentIdOf[workspaceId] != 0) revert AlreadyRegistered(workspaceId);

        agentId = _nextAgentId++;
        _agentIdOf[workspaceId] = agentId;
        _workspaceOf[agentId] = workspaceId;
        _ownerOf[agentId] = owner_;
        emit WorkspaceRegistered(agentId, workspaceId, owner_);
    }

    function setKybStatus(uint256 agentId, bool approved) external onlyRole(ISSUER_ROLE) {
        _requireExists(agentId);
        _kybApproved[agentId] = approved;
        emit KybStatusSet(agentId, approved);
    }

    function setWorkspaceOwner(uint256 agentId, address newOwner) external onlyRole(ISSUER_ROLE) {
        _requireExists(agentId);
        if (newOwner == address(0)) revert ZeroAddress();
        _ownerOf[agentId] = newOwner;
        emit WorkspaceOwnerSet(agentId, newOwner);
    }

    function agentIdOf(bytes32 workspaceId) external view returns (uint256) {
        return _agentIdOf[workspaceId];
    }

    function workspaceOf(uint256 agentId) external view returns (bytes32) {
        return _workspaceOf[agentId];
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _ownerOf[agentId];
    }

    function kybApproved(uint256 agentId) external view returns (bool) {
        return _kybApproved[agentId];
    }

    function exists(uint256 agentId) public view returns (bool) {
        return _workspaceOf[agentId] != bytes32(0);
    }

    function _requireExists(uint256 agentId) internal view {
        if (!exists(agentId)) revert UnknownAgent(agentId);
    }
}

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
    struct KybState { bool approved; uint64 observedAt; uint64 validUntil; uint64 version; bytes32 operationId; }
    mapping(uint256 => KybState) internal _kyb;

    error AlreadyRegistered(bytes32 workspaceId);
    error UnknownAgent(uint256 agentId);
    error ZeroAddress();
    error ZeroWorkspaceId();
    error StaleKybVersion(uint64 current, uint64 received);

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
        KybState storage s = _kyb[agentId]; s.approved = approved; s.observedAt = uint64(block.timestamp); s.validUntil = 0; s.version += 1;
        emit KybStatusSet(agentId, approved);
    }

    function setKybStatus(uint256 agentId, bool approved, uint64 validUntil, uint64 version, bytes32 operationId) external onlyRole(ISSUER_ROLE) {
        _requireExists(agentId); KybState storage s = _kyb[agentId]; if (version <= s.version) revert StaleKybVersion(s.version, version); s.approved = approved; s.observedAt = uint64(block.timestamp); s.validUntil = validUntil; s.version = version; s.operationId = operationId; emit KybStatusSet(agentId, approved);
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
        KybState memory s = _kyb[agentId]; return s.approved && (s.validUntil == 0 || block.timestamp <= s.validUntil);
    }

    function kybState(uint256 agentId) external view returns (bool approved, uint64 observedAt, uint64 validUntil, uint64 version, bytes32 operationId) { _requireExists(agentId); KybState memory s = _kyb[agentId]; return (s.approved, s.observedAt, s.validUntil, s.version, s.operationId); }

    function exists(uint256 agentId) public view returns (bool) {
        return _workspaceOf[agentId] != bytes32(0);
    }

    function _requireExists(uint256 agentId) internal view {
        if (!exists(agentId)) revert UnknownAgent(agentId);
    }
}

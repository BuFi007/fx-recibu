// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WorkspaceOperatingReserve — the seller's first-loss capital (SPEC §3.2, §4.8 layer 2)
///
///  seller posts USDC bond ──▶ balanceOf[agentId]
///        │  (required before lockInvoice funds for Moderate/Developing tiers)
///        ▼
///  DEFAULT: InvoiceShelf.sweepFor(agentId, need) burns the SELLER's capital
///           BEFORE any LP tranche takes a loss — the defector pays first.
///  withdraw: only the amount above the shelf-required minimum, and never while frozen.
contract WorkspaceOperatingReserve is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant SHELF_ROLE = keccak256("SHELF_ROLE");

    IERC20 public immutable USDC;

    mapping(uint256 => uint256) public balanceOf; // agentId → posted reserve
    /// @dev set by the shelf as outstanding changes: the floor below which withdrawals revert
    mapping(uint256 => uint256) public requiredOf;

    event BondPosted(uint256 indexed agentId, address indexed from, uint256 amount);
    event Swept(uint256 indexed agentId, uint256 requested, uint256 covered);
    event RequiredSet(uint256 indexed agentId, uint256 required);
    event Withdrawn(uint256 indexed agentId, address indexed to, uint256 amount);

    error ZeroAmount();
    error BelowRequired(uint256 balance, uint256 required);

    constructor(IERC20 usdc, address admin) {
        USDC = usdc;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice anyone may post a bond on behalf of a workspace (typically its owner)
    function postBond(uint256 agentId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[agentId] += amount;
        emit BondPosted(agentId, msg.sender, amount);
    }

    /// @notice shelf keeps the withdrawal floor in sync with outstanding exposure
    function setRequired(uint256 agentId, uint256 required) external onlyRole(SHELF_ROLE) {
        requiredOf[agentId] = required;
        emit RequiredSet(agentId, required);
    }

    /// @notice §4.8 layer 2: consume the seller's reserve toward a shortfall.
    ///         Transfers what it can cover to the shelf; returns the covered amount.
    function sweepFor(uint256 agentId, uint256 need) external onlyRole(SHELF_ROLE) returns (uint256 covered) {
        uint256 bal = balanceOf[agentId];
        covered = need < bal ? need : bal;
        if (covered > 0) {
            balanceOf[agentId] = bal - covered;
            USDC.safeTransfer(msg.sender, covered);
        }
        emit Swept(agentId, need, covered);
    }

    /// @notice withdraw the surplus above the shelf-required floor to the workspace owner.
    ///         The shelf zeroes `requiredOf` only when the workspace has no exposure and
    ///         is not frozen, so first-loss capital can never front-run a default.
    function withdrawSurplus(uint256 agentId, address to, uint256 amount) external onlyRole(SHELF_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[agentId];
        if (bal < amount || bal - amount < requiredOf[agentId]) revert BelowRequired(bal, requiredOf[agentId]);
        balanceOf[agentId] = bal - amount;
        USDC.safeTransfer(to, amount);
        emit Withdrawn(agentId, to, amount);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IERC2612 — permit (EIP-2612). Signature-based ERC-20 approval, so a payer can
///        approve + pay in one tx without a prior on-chain `approve`. Fallback for tokens
///        that support permit but not ERC-3009.
interface IERC2612 {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    function nonces(address owner) external view returns (uint256);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

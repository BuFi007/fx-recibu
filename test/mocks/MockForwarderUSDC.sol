// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockForwarderUSDC
 * @notice Minimal ERC-20 mock that mimics USDC: 6 decimals, freely mintable.
 */
contract MockForwarderUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint any amount to any address (test helper — no access control).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

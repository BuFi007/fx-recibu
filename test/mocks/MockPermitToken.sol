// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title MockPermitToken — ERC-2612 (permit) token via OZ, for the payWithPermit path.
contract MockPermitToken is ERC20Permit {
    constructor() ERC20("Euro Coin", "EURC") ERC20Permit("Euro Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

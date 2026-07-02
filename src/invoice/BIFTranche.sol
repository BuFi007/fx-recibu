// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BIFTranche — bIF-A / bIF-B / bIF-C LP share token (SPEC §3.4/§6)
/// @notice ERC-20, 18 decimals, no fee-on-transfer, mint/burn ONLY by InvoiceShelf.
///         Losses fill C→B→A (waterfall); yield distributes A→B→C (D20 split).
contract BIFTranche is ERC20 {
    address public immutable SHELF;

    error OnlyShelf();

    modifier onlyShelf() {
        if (msg.sender != SHELF) revert OnlyShelf();
        _;
    }

    constructor(string memory name_, string memory symbol_, address shelf) ERC20(name_, symbol_) {
        SHELF = shelf;
    }

    function mint(address to, uint256 amount) external onlyShelf {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyShelf {
        _burn(from, amount);
    }
}

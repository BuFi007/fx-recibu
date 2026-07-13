// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InvoiceShelf} from "../../src/invoice/InvoiceShelf.sol";
import {BUFIOracle} from "../../src/invoice/BUFIOracle.sol";

contract OracleShareMock is ERC20 {
    constructor() ERC20("Oracle Share", "ORACLE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ABI-compatible with the two InvoiceShelf getters BUFIOracle reads. Returning
///      an address for `tranches(uint8)` matches the ABI encoding of BIFTranche.
contract OracleShelfMock {
    OracleShareMock public immutable SHARE;
    uint256 public assets;

    constructor(OracleShareMock share) {
        SHARE = share;
    }

    function tranches(uint8) external view returns (address) {
        return address(SHARE);
    }

    function trancheAssets(uint8) external view returns (uint256) {
        return assets;
    }

    function setAssets(uint256 assets_) external {
        assets = assets_;
    }
}

contract BUFIOracleAccessTest is Test {
    address internal admin = makeAddr("admin");
    address internal outsider = makeAddr("outsider");

    OracleShareMock internal share;
    OracleShelfMock internal shelf;
    BUFIOracle internal oracle;

    function setUp() public {
        share = new OracleShareMock();
        shelf = new OracleShelfMock(share);
        share.mint(address(this), 100e18);
        shelf.setAssets(100e6);
        oracle = new BUFIOracle(InvoiceShelf(address(shelf)), 2, admin);
    }

    function test_priceRevertsUntilOpsSeedsBaseline() public {
        vm.expectRevert(BUFIOracle.Uninitialized.selector);
        oracle.price();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, oracle.OPS_ROLE()
            )
        );
        vm.prank(outsider);
        oracle.observe();
        assertEq(oracle.lastObserved(), 0);

        vm.prank(admin);
        assertEq(oracle.observe(), 1e24);
        assertEq(oracle.lastObserved(), 1e24);
        assertEq(oracle.price(), 1e24);
    }

    function test_permissionlessProtectiveObserveCannotRatchetBaseline() public {
        vm.prank(admin);
        oracle.observe();

        shelf.setAssets(95e6);
        vm.prank(outsider);
        assertEq(oracle.observe(), 0.95e24);
        assertEq(oracle.lastObserved(), 1e24, "outsider cannot rebase the breaker");
        assertFalse(oracle.tripped());

        shelf.setAssets(89e6);
        vm.prank(outsider);
        assertEq(oracle.observe(), 1e24, "trip returns the last trusted mark");
        assertTrue(oracle.tripped());
        vm.expectRevert(BUFIOracle.Paused.selector);
        oracle.price();
    }

    function test_opsMayAdvanceTrustedBaselineWithinBound() public {
        vm.startPrank(admin);
        oracle.observe();
        shelf.setAssets(95e6);
        assertEq(oracle.observe(), 0.95e24);
        vm.stopPrank();

        assertEq(oracle.lastObserved(), 0.95e24);
        assertEq(oracle.price(), 0.95e24);
    }
}

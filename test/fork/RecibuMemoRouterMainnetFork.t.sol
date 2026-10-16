// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReceivableEscrow} from "../../src/rails/ReceivableEscrow.sol";
import {RecibuMemoRouter} from "../../src/rails/RecibuMemoRouter.sol";
import {IInvoiceShelf} from "../../src/interfaces/IInvoiceShelf.sol";
import {DeployRecibuMemoRouterMainnet} from "../../script/DeployRecibuMemoRouterMainnet.s.sol";

contract FundedShelf {
    function invoiceStatus(uint256) external pure returns (IInvoiceShelf.Status) {
        return IInvoiceShelf.Status.Funded;
    }
}

/// @notice Mainnet fork checks; each skips when its RPC is unreachable.
contract RecibuMemoRouterMainnetForkTest is Test {
    address internal constant SAFE = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;

    function _fork(string memory envKey, string memory url) internal returns (bool) {
        try vm.createSelectFork(vm.envOr(envKey, url)) {
            return true;
        } catch {
            return false;
        }
    }

    function _check(uint256 chainId, bool payE2E) internal {
        assertEq(block.chainid, chainId);
        DeployRecibuMemoRouterMainnet s = new DeployRecibuMemoRouterMainnet();

        // without a shelf: escrows only
        DeployRecibuMemoRouterMainnet.Result memory r0 = s.deployAll(SAFE, address(0));
        assertEq(r0.router, address(0));

        address shelf = address(new FundedShelf());
        DeployRecibuMemoRouterMainnet.Result memory r = s.deployAll(SAFE, shelf);
        assertEq(r.escrows[0], r0.escrows[0]); // idempotent
        RecibuMemoRouter router = RecibuMemoRouter(r.router);
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), SAFE));
        assertFalse(router.hasRole(router.DEFAULT_ADMIN_ROLE(), address(s)));
        assertFalse(router.hasRole(router.DEFAULT_ADMIN_ROLE(), msg.sender));
        assertEq(address(router.SHELF()), shelf);

        for (uint256 i; i < r.tokens.length; ++i) {
            ReceivableEscrow e = ReceivableEscrow(r.escrows[i]);
            assertEq(address(e.USDC()), r.tokens[i]);
            assertTrue(e.hasRole(e.DEFAULT_ADMIN_ROLE(), SAFE));
            assertFalse(e.hasRole(e.DEFAULT_ADMIN_ROLE(), address(s)));
            // the Safe batch from the handoff
            vm.startPrank(SAFE);
            router.setToken(r.tokens[i], true, s.CAPS(), e);
            e.grantRole(e.ROUTER_ROLE(), address(router));
            vm.stopPrank();
            (bool allowed, uint8 caps,) = router.tokenConfig(r.tokens[i]);
            assertTrue(allowed);
            assertEq(caps, 3);
        }

        if (payE2E) {
            address payer = makeAddr("payer");
            deal(r.tokens[0], payer, 1_000e6);
            vm.startPrank(payer);
            IERC20(r.tokens[0]).approve(address(router), 250e6);
            router.pay(r.tokens[0], 7, 0, 250e6);
            vm.stopPrank();
            assertEq(ReceivableEscrow(r.escrows[0]).escrowedOf(7), 250e6);
            assertEq(IERC20(r.tokens[0]).balanceOf(r.escrows[0]), 250e6);
        }
    }

    function test_fork_arcMainnet() public {
        if (!_fork("ARC_MAINNET_RPC_URL", "https://rpc.mainnet.arc.io")) return vm.skip(true);
        _check(5042, false); // Arc USDC is the native-balance precompile: no `deal`
    }

    function test_fork_avalancheMainnet() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        _check(43114, true);
    }

    function test_guardRejectsOtherChains() public {
        DeployRecibuMemoRouterMainnet s = new DeployRecibuMemoRouterMainnet();
        uint256[4] memory bad = [uint256(1), 5042002, 43113, 31337];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DeployRecibuMemoRouterMainnet.ChainNotAllowed.selector, bad[i]));
            s.tokensFor(bad[i]);
        }
    }

    function test_rejectsEoaAdmin() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        DeployRecibuMemoRouterMainnet s = new DeployRecibuMemoRouterMainnet();
        vm.expectRevert(
            abi.encodeWithSelector(DeployRecibuMemoRouterMainnet.AdminMustBeContract.selector, address(0xBEEF))
        );
        s.deployAll(address(0xBEEF), address(0));
    }
}

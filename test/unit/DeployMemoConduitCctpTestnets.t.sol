// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit} from "../../src/rails/MemoConduit.sol";
import {DeployMemoConduitCctpTestnets} from "../../script/DeployMemoConduitCctpTestnets.s.sol";
import {DeployMemoConduitTestnets} from "../../script/DeployMemoConduitTestnets.s.sol";

contract DeployMemoConduitCctpTestnetsTest is Test {
    // Arachnid deterministic-deployment-proxy runtime bytecode.
    bytes constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployMemoConduitCctpTestnets script;

    function setUp() public {
        script = new DeployMemoConduitCctpTestnets();
        vm.etch(script.CREATE2_DEPLOYER(), ARACHNID_RUNTIME);
        vm.etch(script.ADDRESS_BOOK(), hex"00");
    }

    function test_refusesMainnetsAndUnknownChains() public {
        uint256[12] memory bad = [uint256(1), 5042, 43114, 8453, 42161, 10, 137, 130, 143, 421614, 11155420, 999999];
        for (uint256 i; i < bad.length; ++i) {
            vm.chainId(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitCctpTestnets.ChainNotAllowed.selector, bad[i]));
            script.run();
        }
    }

    function test_refusesWithoutAddressBook() public {
        vm.etch(script.ADDRESS_BOOK(), "");
        vm.chainId(84532);
        vm.expectRevert(DeployMemoConduitCctpTestnets.AddressBookMissing.selector);
        script.run();
    }

    function test_perChainTokenLists() public view {
        _assertTokens(11155111, script.USDC_ETH_SEPOLIA(), script.EURC_ETH_SEPOLIA(), script.CIRBTC_ETH_SEPOLIA());
        _assertTokens(84532, script.USDC_BASE_SEPOLIA(), script.EURC_BASE_SEPOLIA(), address(0));
        _assertTokens(43113, script.USDC_FUJI(), script.EURC_FUJI(), address(0));
        _assertTokens(5042002, script.USDC_ARC_TESTNET(), script.EURC_ARC_TESTNET(), script.CIRBTC_ARC_TESTNET());
    }

    function test_deploysAtPredictedAddressWithRoutesAndIsIdempotent() public {
        uint256[4] memory ok = [uint256(11155111), 84532, 43113, 5042002];
        for (uint256 i; i < ok.length; ++i) {
            vm.chainId(ok[i]);
            address predicted = script.predict(ok[i]);
            assertEq(predicted.code.length, 0);

            MemoConduit c = script.run();
            assertEq(address(c), predicted);
            assertEq(address(c.ADDRESS_BOOK()), script.ADDRESS_BOOK());
            address[] memory t = script.tokensFor(ok[i]);
            for (uint256 j; j < t.length; ++j) {
                assertTrue(c.supportedToken(t[j]));
            }
            assertFalse(c.supportedToken(address(0xBEEF)));

            // Every token except Sepolia USDC has at least one route, and every route resolves.
            _assertRoutes(c, ok[i]);

            bytes32 codeHash = predicted.codehash;
            MemoConduit again = script.run();
            assertEq(address(again), predicted);
            assertEq(predicted.codehash, codeHash);
        }
    }

    function test_cctpSaltNeverShadowsTheMemoOnlyConduits() public {
        DeployMemoConduitTestnets v1 = new DeployMemoConduitTestnets();
        assertTrue(script.SALT() != v1.SALT());
        assertTrue(script.predict(84532) != v1.predict(84532));
        assertTrue(script.predict(11155111) != v1.predict(11155111));
    }

    function _assertRoutes(MemoConduit c, uint256 chainId) internal view {
        uint256[4] memory chains = [uint256(11155111), 84532, 43113, 5042002];
        address[] memory t = script.tokensFor(chainId);
        for (uint256 j; j < t.length; ++j) {
            uint8 protocol = j == 0 ? c.CCTP_V2_USDC() : (j == 1 ? c.CCTPX_EURC() : c.CCTPX_CIRBTC());
            uint256 routes;
            for (uint256 k; k < chains.length; ++k) {
                if (chains[k] == chainId) continue;
                try c.bridgeRouteOf(protocol, t[j], chains[k]) returns (uint32, uint32, address remote, address messenger) {
                    assertTrue(remote != address(0));
                    assertEq(messenger, protocol == c.CCTP_V2_USDC() ? c.CCTP_TOKEN_MESSENGER() : c.CCTPX_SERVICE());
                    ++routes;
                } catch {}
            }
            if (chainId == 11155111 && j == 0) assertEq(routes, 0, "Sepolia USDC is local-memo only");
            else assertGt(routes, 0, "token has no bridge route");
        }
    }

    function _assertTokens(uint256 chainId, address a, address b, address cc) internal view {
        address[] memory t = script.tokensFor(chainId);
        assertEq(t.length, cc == address(0) ? 2 : 3);
        assertEq(t[0], a);
        assertEq(t[1], b);
        if (cc != address(0)) assertEq(t[2], cc);
    }
}

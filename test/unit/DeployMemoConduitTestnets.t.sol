// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit} from "../../src/rails/MemoConduit.sol";
import {DeployMemoConduitTestnets} from "../../script/DeployMemoConduitTestnets.s.sol";

contract DeployMemoConduitTestnetsTest is Test {
    // Arachnid deterministic-deployment-proxy runtime bytecode.
    bytes constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployMemoConduitTestnets script;

    function setUp() public {
        script = new DeployMemoConduitTestnets();
        vm.etch(script.CREATE2_DEPLOYER(), ARACHNID_RUNTIME);
        vm.etch(script.ADDRESS_BOOK(), hex"00");
    }

    function test_refusesMainnetsAndUnknownChains() public {
        uint256[11] memory bad = [uint256(1), 5042, 43114, 8453, 42161, 10, 137, 130, 143, 80002, 999999];
        for (uint256 i; i < bad.length; ++i) {
            vm.chainId(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitTestnets.ChainNotAllowed.selector, bad[i]));
            script.run();
        }
    }

    function test_refusesChainsThatAlreadyHaveAConduit() public {
        uint256[2] memory done = [uint256(5042002), 43113];
        for (uint256 i; i < done.length; ++i) {
            vm.chainId(done[i]);
            vm.expectRevert(
                abi.encodeWithSelector(DeployMemoConduitTestnets.AlreadyDeployedElsewhere.selector, done[i])
            );
            script.run();
        }
    }

    function test_perChainTokenLists() public view {
        address[] memory t = script.tokensFor(11155111);
        assertEq(t.length, 2);
        assertEq(t[0], 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        assertEq(t[1], 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4);

        t = script.tokensFor(84532);
        assertEq(t.length, 2);
        assertEq(t[0], 0x036CbD53842c5426634e7929541eC2318f3dCF7e);
        assertEq(t[1], 0x808456652fdb597867f38412077A9182bf77359F);

        _single(421614, 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);
        _single(11155420, 0x5fd84259d66Cd46123540766Be93DFE6D43130D7);
        _single(1301, 0x31d0220469e10c4E71834a79b1f276d740d3768F);
        _single(10143, 0x534b2f3A21130d7a60830c2Df862319e593943A3);
    }

    function test_deploysAtPredictedAddressWithTokensAndIsIdempotent() public {
        uint256[6] memory ok = [uint256(11155111), 84532, 421614, 11155420, 1301, 10143];
        for (uint256 i; i < ok.length; ++i) {
            vm.chainId(ok[i]);
            address predicted = script.predict(ok[i]);
            assertEq(predicted.code.length, 0);

            MemoConduit c = script.run();
            assertEq(address(c), predicted);
            assertGt(predicted.code.length, 0);
            assertEq(address(c.ADDRESS_BOOK()), script.ADDRESS_BOOK());
            address[] memory t = script.tokensFor(ok[i]);
            for (uint256 j; j < t.length; ++j) {
                assertTrue(c.supportedToken(t[j]));
            }
            assertFalse(c.supportedToken(address(0xBEEF)));

            // Re-run: same address, no second CREATE2 (which would revert on collision).
            bytes32 codeHash = predicted.codehash;
            MemoConduit again = script.run();
            assertEq(address(again), predicted);
            assertEq(predicted.codehash, codeHash);
        }
    }

    function test_differentTokenListsGiveDifferentAddresses() public view {
        assertTrue(script.predict(11155111) != script.predict(421614));
        // Same token *count* but different token → different address too.
        assertTrue(script.predict(421614) != script.predict(11155420));
    }

    function _single(uint256 chainId, address usdc) internal view {
        address[] memory t = script.tokensFor(chainId);
        assertEq(t.length, 1);
        assertEq(t[0], usdc);
    }
}

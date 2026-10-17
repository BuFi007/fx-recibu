// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CctpDepositForwarderFactory} from "../../src/rails/cctp/CctpDepositForwarderFactory.sol";
import {DeployCctpDepositForwarder} from "../../script/DeployCctpDepositForwarder.s.sol";

contract DeployCctpDepositForwarderTest is Test {
    bytes constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployCctpDepositForwarder script;

    function setUp() public {
        script = new DeployCctpDepositForwarder();
        vm.etch(script.CREATE2_DEPLOYER(), ARACHNID_RUNTIME);
        vm.etch(script.USDC_BASE_SEPOLIA(), hex"00");
        vm.etch(script.TOKEN_MESSENGER_V2_TESTNET(), hex"00");
    }

    function test_refusesBaseMainnet() public {
        vm.chainId(8453);
        vm.expectRevert(DeployCctpDepositForwarder.MainnetNotAuthorized.selector);
        script.run();
    }

    function test_refusesEveryOtherChain() public {
        uint256[8] memory bad = [uint256(1), 5042, 5042002, 43114, 43113, 11155111, 421614, 999999];
        for (uint256 i; i < bad.length; ++i) {
            vm.chainId(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployCctpDepositForwarder.ChainNotAllowed.selector, bad[i]));
            script.run();
        }
    }

    function test_deploysAtPredictedAddressesAndIsIdempotent() public {
        vm.chainId(84532);
        (address impl, address factory) = script.run();
        assertEq(impl, script.predictImplementation());
        assertEq(factory, script.predictFactory(84532));
        assertGt(impl.code.length, 0);
        CctpDepositForwarderFactory f = CctpDepositForwarderFactory(factory);
        assertEq(f.implementation(), impl);
        assertEq(f.usdc(), 0x036CbD53842c5426634e7929541eC2318f3dCF7e);
        assertEq(f.tokenMessenger(), 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA);

        (address impl2, address factory2) = script.run();
        assertEq(impl2, impl);
        assertEq(factory2, factory);
    }

    function test_recordsBaseMainnetConstants() public view {
        assertEq(script.USDC_BASE_MAINNET(), 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(script.TOKEN_MESSENGER_V2_MAINNET(), 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
    }
}

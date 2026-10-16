// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit, IMemoCctpTokenMessengerV2} from "../../src/rails/MemoConduit.sol";
import {DeployMemoConduitCctpMainnet} from "../../script/DeployMemoConduitCctpMainnet.s.sol";

/// @notice Hub-and-spoke mainnet fork checks; each skips when its RPC is unreachable.
///         Override with ARC_MAINNET_RPC_URL / AVALANCHE_RPC_URL.
contract MemoConduitCctpMainnetForkTest is Test {
    address internal constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant MINTER = 0xfd78EE919681417d192449715b2594ab58f5D002;
    address internal constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    function _fork(string memory envKey, string memory fallbackUrl) internal returns (bool) {
        try vm.createSelectFork(vm.envOr(envKey, fallbackUrl)) {
            return true;
        } catch {
            return false;
        }
    }

    function test_fork_avalancheSpoke_repaysHubOnly() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        assertEq(block.chainid, 43114);
        DeployMemoConduitCctpMainnet script = new DeployMemoConduitCctpMainnet();
        MemoConduit c = script.run();
        assertEq(address(c), script.predict(43114));
        assertEq(address(script.run()), address(c)); // idempotent

        assertEq(c.CCTP_TOKEN_MESSENGER(), MESSENGER);
        assertEq(c.CCTP_TOKEN_MINTER(), MINTER);
        assertEq(c.CCTP_MESSAGE_TRANSMITTER(), TRANSMITTER);
        assertGt(TRANSMITTER.code.length, 0);
        assertGt(c.CCTPX_SERVICE().code.length, 0);
        assertEq(c.CCTPX_EURC_MANAGER(), address(0));
        assertEq(IMemoCctpTokenMessengerV2(MESSENGER).localMinter(), MINTER);
        assertEq(IMemoCctpTokenMessengerV2(MESSENGER).remoteTokenMessengers(26), bytes32(uint256(uint160(MESSENGER))));

        address usdc = script.USDC_AVAX();
        (uint32 s, uint32 d, address remoteToken, address m) = c.bridgeRouteOf(1, usdc, 5042);
        assertEq(s, 1);
        assertEq(d, 26);
        assertEq(remoteToken, script.USDC_ARC());
        assertEq(m, MESSENGER);

        address eurc = script.EURC_AVAX();
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(2, eurc, 5042); // mainnet CCTPx not routed
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(1, usdc, 43113); // no cross-environment routes
    }

    function test_fork_arcHub_canReceive_butIsNotASpoke() public {
        if (!_fork("ARC_MAINNET_RPC_URL", "https://rpc.mainnet.arc.io")) return vm.skip(true);
        assertEq(block.chainid, 5042);
        // the hub's messenger accepts mints from the Avalanche domain
        assertEq(IMemoCctpTokenMessengerV2(MESSENGER).remoteTokenMessengers(1), bytes32(uint256(uint160(MESSENGER))));
        assertGt(TRANSMITTER.code.length, 0);
        DeployMemoConduitCctpMainnet script = new DeployMemoConduitCctpMainnet();
        vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitCctpMainnet.ChainNotAllowed.selector, 5042));
        script.run();
    }

    function test_hubToSpokeDirectionRefused() public {
        // a conduit on the hub (never deployed by the script) still refuses hub->spoke
        vm.chainId(5042);
        address[] memory t = new address[](1);
        t[0] = 0x3600000000000000000000000000000000000000;
        DeployMemoConduitCctpMainnet script = new DeployMemoConduitCctpMainnet();
        address book = script.ADDRESS_BOOK();
        vm.etch(book, hex"00");
        MemoConduit c = MemoConduit(address(new ConduitFactory().make(book, t)));
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(1, t[0], 43114);
    }

    function test_guardRejectsOtherChains() public {
        DeployMemoConduitCctpMainnet script = new DeployMemoConduitCctpMainnet();
        uint256[5] memory bad = [uint256(1), 5042, 5042002, 43113, 31337];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitCctpMainnet.ChainNotAllowed.selector, bad[i]));
            script.tokensFor(bad[i]);
        }
    }
}

import {IAddressBook} from "../../src/rails/MemoConduit.sol";
import {MemoConduitCctpConfig} from "../../src/rails/MemoConduitCctpConfig.sol";

contract ConduitFactory {
    function make(address book, address[] memory t) external returns (MemoConduit) {
        return new MemoConduit(IAddressBook(book), t, MemoConduitCctpConfig.mainnet());
    }
}

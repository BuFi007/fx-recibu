// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit, IMemoCctpTokenMessengerV2} from "../../src/rails/MemoConduit.sol";
import {SpokeMemoConduit} from "../../src/rails/SpokeMemoConduit.sol";
import {DeployMemoConduitCctpMainnet} from "../../script/DeployMemoConduitCctpMainnet.s.sol";
import {DeploySpokeMemoConduitMainnet} from "../../script/DeploySpokeMemoConduitMainnet.s.sol";

/// @notice Mainnet fork checks; each skips when its RPC is unreachable.
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

    function _checkout(uint256 chainId, uint256 remote, uint32 localDomain, uint32 remoteDomain) internal {
        assertEq(block.chainid, chainId);
        DeployMemoConduitCctpMainnet script = new DeployMemoConduitCctpMainnet();
        MemoConduit c = script.run();
        assertEq(address(c), script.predict(chainId));
        assertEq(address(script.run()), address(c)); // idempotent
        assertEq(c.CCTP_TOKEN_MESSENGER(), MESSENGER);
        assertEq(c.CCTP_TOKEN_MINTER(), MINTER);
        assertEq(c.CCTP_MESSAGE_TRANSMITTER(), TRANSMITTER);
        assertGt(TRANSMITTER.code.length, 0);
        assertGt(c.CCTPX_SERVICE().code.length, 0);
        assertEq(c.CCTPX_EURC_MANAGER(), address(0));
        assertEq(IMemoCctpTokenMessengerV2(MESSENGER).localMinter(), MINTER);
        assertEq(
            IMemoCctpTokenMessengerV2(MESSENGER).remoteTokenMessengers(remoteDomain),
            bytes32(uint256(uint160(MESSENGER)))
        );
        address[] memory t = script.tokensFor(chainId);
        address[] memory rt = script.tokensFor(remote);
        (uint32 s, uint32 d, address remoteToken, address m) = c.bridgeRouteOf(1, t[0], remote);
        assertEq(s, localDomain);
        assertEq(d, remoteDomain);
        assertEq(remoteToken, rt[0]);
        assertEq(m, MESSENGER);
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(2, t[1], remote); // mainnet CCTPx not routed
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(1, t[0], 43113); // no cross-environment routes
    }

    function test_fork_checkout_arcToAvalanche() public {
        if (!_fork("ARC_MAINNET_RPC_URL", "https://rpc.mainnet.arc.io")) return vm.skip(true);
        _checkout(5042, 43114, 26, 1);
    }

    function test_fork_checkout_avalancheToArc() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        _checkout(43114, 5042, 1, 26);
    }

    function test_fork_spoke_avalancheRepaysArcOnly() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        DeploySpokeMemoConduitMainnet script = new DeploySpokeMemoConduitMainnet();
        SpokeMemoConduit sp = script.run();
        assertEq(address(sp), script.predict(43114));
        assertEq(address(script.run()), address(sp));
        assertEq(sp.CCTP_MESSAGE_TRANSMITTER(), TRANSMITTER);
        (uint32 s, uint32 d, address remoteToken,) = sp.bridgeRouteOf(1, script.USDC_AVAX(), 5042);
        assertEq(s, 1);
        assertEq(d, 26);
        assertEq(remoteToken, script.USDC_ARC());
        address usdc = script.USDC_AVAX();
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, 43114, 1));
        sp.bridgeRouteOf(1, usdc, 1);
    }

    function test_fork_arcHub_acceptsAvalancheMints() public {
        if (!_fork("ARC_MAINNET_RPC_URL", "https://rpc.mainnet.arc.io")) return vm.skip(true);
        assertEq(IMemoCctpTokenMessengerV2(MESSENGER).remoteTokenMessengers(1), bytes32(uint256(uint160(MESSENGER))));
        DeploySpokeMemoConduitMainnet script = new DeploySpokeMemoConduitMainnet();
        vm.expectRevert(abi.encodeWithSelector(DeploySpokeMemoConduitMainnet.ChainNotAllowed.selector, 5042));
        script.run();
    }

    function test_guards() public {
        DeployMemoConduitCctpMainnet c = new DeployMemoConduitCctpMainnet();
        DeploySpokeMemoConduitMainnet sp = new DeploySpokeMemoConduitMainnet();
        uint256[4] memory bad = [uint256(1), 5042002, 43113, 31337];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitCctpMainnet.ChainNotAllowed.selector, bad[i]));
            c.tokensFor(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(DeploySpokeMemoConduitMainnet.ChainNotAllowed.selector, bad[i]));
            sp.tokensFor(bad[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(DeploySpokeMemoConduitMainnet.ChainNotAllowed.selector, 5042));
        sp.tokensFor(5042);
        assertEq(c.tokensFor(5042).length, 2);
    }
}

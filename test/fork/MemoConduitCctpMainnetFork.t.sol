// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit, IMemoCctpTokenMessengerV2} from "../../src/rails/MemoConduit.sol";
import {DeployMemoConduitCctpMainnet} from "../../script/DeployMemoConduitCctpMainnet.s.sol";

/// @notice Mainnet fork checks. Each fork test skips if its RPC is unreachable.
///         Override with ARC_MAINNET_RPC_URL / AVALANCHE_RPC_URL.
contract MemoConduitCctpMainnetForkTest is Test {
    DeployMemoConduitCctpMainnet internal script;

    function _fork(string memory envKey, string memory fallbackUrl) internal returns (bool) {
        string memory url = vm.envOr(envKey, fallbackUrl);
        try vm.createSelectFork(url) {
            return true;
        } catch {
            return false;
        }
    }

    function _check(uint256 chainId, uint256 remote, uint32 localDomain, uint32 remoteDomain) internal {
        assertEq(block.chainid, chainId);
        script = new DeployMemoConduitCctpMainnet();
        MemoConduit c = script.run();
        assertEq(address(c), script.predict(chainId));
        assertGt(address(c).code.length, 0);
        assertEq(address(script.run()), address(c)); // idempotent

        address messenger = c.CCTP_TOKEN_MESSENGER();
        assertEq(messenger, 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
        assertGt(messenger.code.length, 0);
        assertGt(c.CCTP_TOKEN_MINTER().code.length, 0);
        assertGt(c.CCTPX_SERVICE().code.length, 0);
        assertEq(IMemoCctpTokenMessengerV2(messenger).localMinter(), c.CCTP_TOKEN_MINTER());
        assertEq(
            IMemoCctpTokenMessengerV2(messenger).remoteTokenMessengers(remoteDomain),
            bytes32(uint256(uint160(messenger)))
        );
        assertEq(c.CCTPX_EURC_MANAGER(), address(0));

        address usdc = script.tokensFor(chainId)[0];
        address eurc = script.tokensFor(chainId)[1];
        assertTrue(c.supportedToken(usdc) && c.supportedToken(eurc));
        (uint32 s, uint32 d, address remoteToken, address m) = c.bridgeRouteOf(1, usdc, remote);
        assertEq(s, localDomain);
        assertEq(d, remoteDomain);
        assertEq(remoteToken, script.tokensFor(remote)[0]);
        assertEq(m, messenger);

        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(2, eurc, remote); // mainnet CCTPx not routed
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        c.bridgeRouteOf(1, usdc, 43113); // no cross-environment routes
    }

    function test_fork_arcMainnet() public {
        if (!_fork("ARC_MAINNET_RPC_URL", "https://rpc.mainnet.arc.io")) return vm.skip(true);
        _check(5042, 43114, 26, 1);
    }

    function test_fork_avalancheMainnet() public {
        if (!_fork("AVALANCHE_RPC_URL", "https://avalanche-c-chain-rpc.publicnode.com")) return vm.skip(true);
        _check(43114, 5042, 1, 26);
    }

    function test_guardRejectsOtherChains() public {
        script = new DeployMemoConduitCctpMainnet();
        uint256[5] memory bad = [uint256(1), 5042002, 43113, 8453, 31337];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DeployMemoConduitCctpMainnet.ChainNotAllowed.selector, bad[i]));
            script.tokensFor(bad[i]);
        }
    }
}

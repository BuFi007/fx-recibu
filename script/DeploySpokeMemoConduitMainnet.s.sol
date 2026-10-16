// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IAddressBook} from "../src/rails/MemoConduit.sol";
import {SpokeMemoConduit} from "../src/rails/SpokeMemoConduit.sol";
import {MemoConduitCctpConfig} from "../src/rails/MemoConduitCctpConfig.sol";

/// @title DeploySpokeMemoConduitMainnet — one-way DeFi repayment rail on the Avalanche spoke.
/// @notice AVALANCHE 43114 ONLY. Avalanche (domain 1) -> Arc hub (domain 26), USDC via CCTP V2.
///         Tokens: USDC only (DeFi repayments are USDC-denominated on the hub). No owner.
///         Salt keccak256("bufi.spoke-memo-conduit.mainnet.v1"). Arachnid CREATE2, idempotent.
contract DeploySpokeMemoConduitMainnet is Script {
    address public constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("bufi.spoke-memo-conduit.mainnet.v1");
    address public constant USDC_AVAX = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address public constant USDC_ARC = 0x3600000000000000000000000000000000000000;

    error ChainNotAllowed(uint256 chainId);
    error DependencyMissing(address dep);
    error DeployFailed();

    function tokensFor(uint256 chainId) public pure returns (address[] memory t) {
        if (chainId != 43114) revert ChainNotAllowed(chainId);
        t = new address[](1);
        t[0] = USDC_AVAX;
    }

    function initCodeFor(uint256 chainId) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(SpokeMemoConduit).creationCode,
            abi.encode(IAddressBook(ADDRESS_BOOK), tokensFor(chainId), MemoConduitCctpConfig.mainnet())
        );
    }

    function predict(uint256 chainId) public pure returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initCodeFor(chainId))));
        return address(uint160(uint256(h)));
    }

    function run() external returns (SpokeMemoConduit spoke) {
        bytes memory initCode = initCodeFor(block.chainid); // reverts off 43114
        address[3] memory deps = [ADDRESS_BOOK, CREATE2_DEPLOYER, MemoConduitCctpConfig.mainnet().tokenMessenger];
        for (uint256 i; i < deps.length; ++i) {
            if (deps[i].code.length == 0) revert DependencyMissing(deps[i]);
        }
        address predicted = predict(block.chainid);
        console2.log("chainId", block.chainid);
        console2.log("predicted SpokeMemoConduit", predicted);
        if (predicted.code.length != 0) {
            console2.log("already deployed - skipping");
            return SpokeMemoConduit(predicted);
        }
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initCode));
        vm.stopBroadcast();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != predicted) revert DeployFailed();
        console2.log("deployed SpokeMemoConduit", predicted);
        return SpokeMemoConduit(predicted);
    }
}

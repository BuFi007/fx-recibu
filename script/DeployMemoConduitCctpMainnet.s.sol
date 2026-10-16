// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MemoConduitCctpConfig} from "../src/rails/MemoConduitCctpConfig.sol";
import {Script, console2} from "forge-std/Script.sol";
import {MemoConduit, IAddressBook} from "../src/rails/MemoConduit.sol";

/// @title DeployMemoConduitCctpMainnet — the CHECKOUT MemoConduit with CCTP, on MAINNET.
/// @notice Allowlist: ARC 5042 (CCTP domain 26) and AVALANCHE C-Chain 43114 (CCTP domain 1).
///         Bidirectional checkout: USDC bridges Arc <-> Avalanche both ways (CCTP V2); EURC is
///         local-memo only (no mainnet CCTPx manager configured -> fails closed). CCTP addresses
///         are constructor immutables (MemoConduitCctpConfig.mainnet()). No owner.
///         The one-way DeFi repayment rail is SpokeMemoConduit (DeploySpokeMemoConduitMainnet).
///         Salt keccak256("bufi.memo-conduit.cctp.mainnet.v1"); the v1 memo-only conduits
///         (Arc 0x5163...6ba2, Avax 0x5362...fFe2, commit 6f5d17b) are untouched.
///
///   forge script script/DeployMemoConduitCctpMainnet.s.sol --rpc-url <rpc> \
///     --private-key $DEPLOYER_PRIVATE_KEY [--broadcast --slow]
contract DeployMemoConduitCctpMainnet is Script {
    address public constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("bufi.memo-conduit.cctp.mainnet.v1");

    address public constant USDC_ARC = 0x3600000000000000000000000000000000000000;
    address public constant EURC_ARC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address public constant USDC_AVAX = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address public constant EURC_AVAX = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD;

    error ChainNotAllowed(uint256 chainId);
    error AddressBookMissing();
    error DependencyMissing(address dep);
    error DeployFailed();

    function tokensFor(uint256 chainId) public pure returns (address[] memory t) {
        t = new address[](2);
        if (chainId == 5042) {
            (t[0], t[1]) = (USDC_ARC, EURC_ARC);
        } else if (chainId == 43114) {
            (t[0], t[1]) = (USDC_AVAX, EURC_AVAX);
        } else {
            revert ChainNotAllowed(chainId);
        }
    }

    function initCodeFor(uint256 chainId) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(MemoConduit).creationCode,
            abi.encode(IAddressBook(ADDRESS_BOOK), tokensFor(chainId), MemoConduitCctpConfig.mainnet())
        );
    }

    function predict(uint256 chainId) public pure returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initCodeFor(chainId))));
        return address(uint160(uint256(h)));
    }

    function run() external returns (MemoConduit conduit) {
        bytes memory initCode = initCodeFor(block.chainid); // reverts off-allowlist
        if (ADDRESS_BOOK.code.length == 0) revert AddressBookMissing();
        if (CREATE2_DEPLOYER.code.length == 0) revert DependencyMissing(CREATE2_DEPLOYER);
        address[] memory t = tokensFor(block.chainid);
        for (uint256 i; i < t.length; ++i) {
            if (t[i].code.length == 0) revert DependencyMissing(t[i]);
        }
        address predicted = predict(block.chainid);
        console2.log("chainId", block.chainid);
        console2.log("predicted MemoConduit", predicted);
        if (predicted.code.length != 0) {
            console2.log("already deployed - skipping");
            return MemoConduit(predicted);
        }
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initCode));
        vm.stopBroadcast();
        if (!ok || ret.length != 20 || address(bytes20(ret)) != predicted) revert DeployFailed();
        conduit = MemoConduit(predicted);
        if (conduit.CCTP_TOKEN_MESSENGER().code.length == 0) revert DependencyMissing(conduit.CCTP_TOKEN_MESSENGER());
        console2.log("deployed MemoConduit", predicted);
    }
}

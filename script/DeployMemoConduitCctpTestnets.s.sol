// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MemoConduitCctpConfig} from "../src/rails/MemoConduitCctpConfig.sol";
import {Script, console2} from "forge-std/Script.sol";
import {MemoConduit, IAddressBook} from "../src/rails/MemoConduit.sol";

/// @title DeployMemoConduitCctpTestnets — the CCTP / CCTPx MemoConduit on the four bridge TESTNETS.
/// @notice Allowlist: ETH-SEPOLIA 11155111, BASE-SEPOLIA 84532, AVAX-FUJI 43113, ARC-TESTNET 5042002.
///         Every other chain reverts, mainnets included. These are the only chains in
///         MemoConduit's `_testnetAsset` route table.
///
///         Token set per chain = the route table's assets plus Sepolia USDC, which is
///         local-memo only (CCTP USDC routes cover Base, Fuji and Arc). Every token carries the
///         FiatToken v2.2 `receiveWithAuthorization(...,bytes)` overload (ERC-1271 payers),
///         probed 2026-10-14: an eth_call with a junk signature reached the signature path on
///         all nine. AddressBook, TokenMessengerV2, TokenMinterV2, the CCTPx service and the
///         EURC manager have code on all four; the cirBTC manager only on Sepolia and Arc.
///
///         A NEW salt, keccak256("bufi.memo-conduit.cctp.v1"), so the CCTP conduit never
///         collides with the v1 (memo-only) conduits, which stay live. Re-running is a no-op
///         when code already exists at the predicted address.
///
///   forge script script/DeployMemoConduitCctpTestnets.s.sol --rpc-url <testnet rpc> \
///     --sender <deployer> [--broadcast]
contract DeployMemoConduitCctpTestnets is Script {
    address public constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("bufi.memo-conduit.cctp.v1");

    address public constant USDC_ETH_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address public constant USDC_FUJI = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address public constant USDC_ARC_TESTNET = 0x3600000000000000000000000000000000000000;
    address public constant EURC_ETH_SEPOLIA = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
    address public constant EURC_BASE_SEPOLIA = 0x808456652fdb597867f38412077A9182bf77359F;
    address public constant EURC_FUJI = 0x5E44db7996c682E92a960b65AC713a54AD815c6B;
    address public constant EURC_ARC_TESTNET = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    address public constant CIRBTC_ETH_SEPOLIA = 0x3a3fe695F684Bf9b9e43CF43C2b895Ea5e392bB3;
    address public constant CIRBTC_ARC_TESTNET = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;

    error ChainNotAllowed(uint256 chainId);
    error AddressBookMissing();
    error DeployFailed();

    /// @notice The fixed token set for `chainId`. Reverts for any chain outside the allowlist.
    function tokensFor(uint256 chainId) public pure returns (address[] memory t) {
        if (chainId == 11155111) return _three(USDC_ETH_SEPOLIA, EURC_ETH_SEPOLIA, CIRBTC_ETH_SEPOLIA);
        if (chainId == 84532) return _two(USDC_BASE_SEPOLIA, EURC_BASE_SEPOLIA);
        if (chainId == 43113) return _two(USDC_FUJI, EURC_FUJI);
        if (chainId == 5042002) return _three(USDC_ARC_TESTNET, EURC_ARC_TESTNET, CIRBTC_ARC_TESTNET);
        revert ChainNotAllowed(chainId);
    }

    function initCodeFor(uint256 chainId) public pure returns (bytes memory) {
        return abi.encodePacked(type(MemoConduit).creationCode, abi.encode(IAddressBook(ADDRESS_BOOK), tokensFor(chainId), MemoConduitCctpConfig.testnet()));
    }

    function predict(uint256 chainId) public pure returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initCodeFor(chainId))));
        return address(uint160(uint256(h)));
    }

    function run() external returns (MemoConduit conduit) {
        bytes memory initCode = initCodeFor(block.chainid); // reverts off-allowlist
        if (ADDRESS_BOOK.code.length == 0) revert AddressBookMissing();
        require(CREATE2_DEPLOYER.code.length != 0, "MemoConduit: no CREATE2 deployer");

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
        console2.log("deployed MemoConduit", predicted);
        return MemoConduit(predicted);
    }

    function _two(address a, address b) private pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }

    function _three(address a, address b, address c) private pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }
}

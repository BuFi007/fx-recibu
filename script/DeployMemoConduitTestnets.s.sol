// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MemoConduit, IAddressBook} from "../src/rails/MemoConduit.sol";

/// @title DeployMemoConduitTestnets — MemoConduit on the remaining EVM TESTNETS.
/// @notice Allowlist: ETH-SEPOLIA 11155111, BASE-SEPOLIA 84532, ARB-SEPOLIA 421614,
///         OP-SEPOLIA 11155420, UNI-SEPOLIA 1301, MONAD-TESTNET 10143. MATIC-AMOY (80002) is
///         not supported by BUFI (founder, 2026-10-11) and is refused.
///         Every other chain reverts — mainnets included. Arc testnet (5042002) and Fuji (43113)
///         already have conduits (0x0282e3a5…, 0xA0d880E0…) and are refused here so they are
///         never shadowed by a second address.
///
///         Token set per chain = only tokens whose implementation carries the FiatToken v2.2
///         `receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)`
///         overload (selector 0x88b7ab63, ERC-1271 payers). Probed 2026-10-11 on public RPCs:
///         selector present in the EIP-1967 (zos) implementation bytecode AND an eth_call with a
///         junk signature reverts "ECRecover: invalid signature 's' value" (signature path
///         reached, not an unknown-selector revert). AddressBook has code on all seven.
///
///         Deployed through the Arachnid CREATE2 deployer with salt keccak256("bufi.memo-conduit.v1")
///         (same as mainnet). The address depends on the init code, so chains with different
///         token lists get different addresses. Re-running is a no-op when code already exists
///         at the predicted address.
///
///   forge script script/DeployMemoConduitTestnets.s.sol --rpc-url <testnet rpc> \
///     --sender <deployer> [--broadcast]
contract DeployMemoConduitTestnets is Script {
    address public constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("bufi.memo-conduit.v1");

    // USDC (FiatToken v2.2 — bytes overload verified)
    address public constant USDC_ETH_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address public constant USDC_ARB_SEPOLIA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address public constant USDC_OP_SEPOLIA = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;
    address public constant USDC_UNI_SEPOLIA = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address public constant USDC_MONAD_TESTNET = 0x534b2f3A21130d7a60830c2Df862319e593943A3;
    // EURC — only on the two chains where it exists (both verified)
    address public constant EURC_ETH_SEPOLIA = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
    address public constant EURC_BASE_SEPOLIA = 0x808456652fdb597867f38412077A9182bf77359F;

    error ChainNotAllowed(uint256 chainId);
    error AlreadyDeployedElsewhere(uint256 chainId);
    error AddressBookMissing();
    error DeployFailed();

    /// @notice The fixed token set for `chainId`. Reverts for any chain outside the allowlist.
    function tokensFor(uint256 chainId) public pure returns (address[] memory t) {
        if (chainId == 11155111) return _two(USDC_ETH_SEPOLIA, EURC_ETH_SEPOLIA);
        if (chainId == 84532) return _two(USDC_BASE_SEPOLIA, EURC_BASE_SEPOLIA);
        if (chainId == 421614) return _one(USDC_ARB_SEPOLIA);
        if (chainId == 11155420) return _one(USDC_OP_SEPOLIA);
        if (chainId == 1301) return _one(USDC_UNI_SEPOLIA);
        if (chainId == 10143) return _one(USDC_MONAD_TESTNET);
        if (chainId == 5042002 || chainId == 43113) revert AlreadyDeployedElsewhere(chainId);
        revert ChainNotAllowed(chainId);
    }

    function initCodeFor(uint256 chainId) public pure returns (bytes memory) {
        return abi.encodePacked(type(MemoConduit).creationCode, abi.encode(IAddressBook(ADDRESS_BOOK), tokensFor(chainId)));
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

    function _one(address a) private pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    function _two(address a, address b) private pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }
}

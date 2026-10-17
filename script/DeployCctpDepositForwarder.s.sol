// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CctpDepositForwarder} from "../src/rails/cctp/CctpDepositForwarder.sol";
import {CctpDepositForwarderFactory} from "../src/rails/cctp/CctpDepositForwarderFactory.sol";

/// @title DeployCctpDepositForwarder — CctpDepositForwarder implementation + factory on Base Sepolia.
/// @notice Neither contract has an owner, admin, upgrade or pause, so the deployer holds no power
///         after this script runs. Both deploy through the Arachnid CREATE2 deployer with fixed
///         salts; re-running is a no-op when code already exists at the predicted addresses.
///
///         Allowlist: BASE-SEPOLIA 84532 only. Base mainnet (8453) constants are recorded below,
///         verified on-chain 2026-10-17, but deploying there is NOT authorized by this script and
///         reverts `MainnetNotAuthorized`.
///
///         Verified on-chain 2026-10-17 (public RPCs):
///           Base Sepolia USDC 0x036C…CF7e: symbol "USDC", 6 decimals.
///           TokenMessengerV2 0x8FE6…2DAA (EIP-1967 proxy, impl 0xf80e…0b76) exposes
///           depositForBurnWithHook; localMessageTransmitter = 0xE737…E275 whose localDomain() = 6.
///           remoteTokenMessengers(26) and remoteTokenMessengers(1) are both set (Arc testnet and
///           Avalanche Fuji routes registered). Arc testnet MessageTransmitterV2 localDomain() = 26.
///           Base mainnet USDC 0x8335…2913 and TokenMessengerV2 0x28b5…cf5d have code; its
///           MessageTransmitterV2 0x81D4…4B64 localDomain() = 6; routes 26 and 1 are registered.
///
///   forge script script/DeployCctpDepositForwarder.s.sol --rpc-url https://sepolia.base.org \
///     --sender <deployer> [--broadcast]
contract DeployCctpDepositForwarder is Script {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant IMPLEMENTATION_SALT = keccak256("bufi.cctp-deposit-forwarder.v1.implementation");
    bytes32 public constant FACTORY_SALT = keccak256("bufi.cctp-deposit-forwarder.v1.factory");

    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address public constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address public constant TOKEN_MESSENGER_V2_TESTNET = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;

    // Recorded only — not deployable from this script.
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    address public constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TOKEN_MESSENGER_V2_MAINNET = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    error ChainNotAllowed(uint256 chainId);
    error MainnetNotAuthorized();
    error DeployFailed();

    function chainConfig(uint256 chainId) public pure returns (address usdc, address tokenMessenger) {
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return (USDC_BASE_SEPOLIA, TOKEN_MESSENGER_V2_TESTNET);
        if (chainId == BASE_MAINNET_CHAIN_ID) revert MainnetNotAuthorized();
        revert ChainNotAllowed(chainId);
    }

    function implementationInitCode() public pure returns (bytes memory) {
        return type(CctpDepositForwarder).creationCode;
    }

    function predictImplementation() public pure returns (address) {
        return _create2(IMPLEMENTATION_SALT, keccak256(implementationInitCode()));
    }

    function factoryInitCode(uint256 chainId) public pure returns (bytes memory) {
        (address usdc, address tokenMessenger) = chainConfig(chainId);
        return abi.encodePacked(
            type(CctpDepositForwarderFactory).creationCode, abi.encode(predictImplementation(), usdc, tokenMessenger)
        );
    }

    function predictFactory(uint256 chainId) public pure returns (address) {
        return _create2(FACTORY_SALT, keccak256(factoryInitCode(chainId)));
    }

    function run() external returns (address implementation, address factory) {
        bytes memory factoryCode = factoryInitCode(block.chainid); // reverts off-allowlist
        require(CREATE2_DEPLOYER.code.length != 0, "CctpDepositForwarder: no CREATE2 deployer");
        (address usdc, address tokenMessenger) = chainConfig(block.chainid);
        require(
            usdc.code.length != 0 && tokenMessenger.code.length != 0, "CctpDepositForwarder: chain constants missing"
        );

        implementation = predictImplementation();
        factory = predictFactory(block.chainid);
        console2.log("chainId", block.chainid);
        console2.log("implementation", implementation);
        console2.log("factory", factory);

        vm.startBroadcast();
        if (implementation.code.length == 0) _deploy(IMPLEMENTATION_SALT, implementationInitCode(), implementation);
        if (factory.code.length == 0) _deploy(FACTORY_SALT, factoryCode, factory);
        vm.stopBroadcast();

        CctpDepositForwarderFactory f = CctpDepositForwarderFactory(factory);
        require(f.implementation() == implementation, "factory implementation mismatch");
        require(f.usdc() == usdc, "factory usdc mismatch");
        require(f.tokenMessenger() == tokenMessenger, "factory messenger mismatch");
    }

    function _deploy(bytes32 salt, bytes memory initCode, address expected) private {
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        if (!ok || expected.code.length == 0) revert DeployFailed();
    }

    function _create2(bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }
}

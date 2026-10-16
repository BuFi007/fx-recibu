// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MemoConduitCctpConfig} from "../src/rails/MemoConduitCctpConfig.sol";
import {Script} from "forge-std/Script.sol";
import {MemoConduit, IAddressBook} from "../src/rails/MemoConduit.sol";

/// @title DeployMemoConduit — Arc TESTNET only (5042002).
/// @notice Token set is fixed at deploy: only tokens whose implementation carries the FiatToken
///         v2.2 `receiveWithAuthorization(..., bytes signature)` overload (ERC-1271 payers).
///         Probed 2026-10-01: USDC + EURC have it on Arc testnet and mainnet. MXNB has it on
///         testnet (left out until it is listed). JPYC has only the v,r,s form; QCAD, AUDF,
///         KRW1 and the Ripio wrapped LATAM tokens have no ERC-3009 at all.
///         Mainnet (5042) needs an audit and a written founder go; this script refuses it.
///
///   forge script script/DeployMemoConduit.s.sol --rpc-url https://rpc.testnet.arc.network \
///     --private-key $DEPLOYER_KEY --broadcast
contract DeployMemoConduit is Script {
    address constant ADDRESS_BOOK = 0x0000000d81083B16EA76dfab46B0315B0eDBF3d0;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC_TESTNET = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    function run() external returns (MemoConduit conduit) {
        require(block.chainid == 5042002, "MemoConduit: Arc testnet only");
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = EURC_TESTNET;
        vm.startBroadcast();
        conduit = new MemoConduit(IAddressBook(ADDRESS_BOOK), tokens, MemoConduitCctpConfig.none());
        vm.stopBroadcast();
    }
}

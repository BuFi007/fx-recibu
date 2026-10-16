// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice Circle dependency set handed to the MemoConduit CONSTRUCTOR (stored as immutables).
///         address(0) disables the corresponding rail (every bridge call fails closed).
struct CctpConfig {
    address tokenMessenger; // CCTP V2 TokenMessengerV2
    address messageTransmitter; // CCTP V2 MessageTransmitterV2 (recorded for indexers / verification)
    address tokenMinter; // CCTP V2 TokenMinterV2
    address ccts; // CCTPx CrossChainTokenService
    address eurcManager; // CCTPx EURC TokenManager
    address cirbtcManager; // CCTPx cirBTC TokenManager
}

/// @notice Reviewed per-environment values. Sources: developers.circle.com
///         /cctp/references/contract-addresses and /cctp/expanded-assets/references/contract-addresses;
///         every mainnet address checked with `cast code` on Arc 5042 and Avalanche 43114 (2026-10-16).
library MemoConduitCctpConfig {
    function none() internal pure returns (CctpConfig memory c) {}

    function testnet() internal pure returns (CctpConfig memory c) {
        c.tokenMessenger = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
        c.messageTransmitter = 0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275;
        c.tokenMinter = 0xb43db544E2c27092c107639Ad201b3dEfAbcF192;
        c.ccts = 0x63753E722bd2C2A5DF6EE19C5106662208B81077;
        c.eurcManager = 0xE5D6eacf2eD5A7F81cC89d2a216F004092c0C2E0;
        c.cirbtcManager = 0xb995F4060c38b7608626d0CCaBE547cdc2c7390A;
    }

    /// @dev Mainnet CCTPx managers are unset: Circle publishes no mainnet EURC/cirBTC tokenId and
    ///      the testnet ids are not registered on mainnet CCTS. Mainnet = CCTP V2 USDC only.
    function mainnet() internal pure returns (CctpConfig memory c) {
        c.tokenMessenger = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
        c.messageTransmitter = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
        c.tokenMinter = 0xfd78EE919681417d192449715b2594ab58f5D002;
        c.ccts = 0x431871229103b780868f8C6BB820cd16ECf942BC;
    }
}

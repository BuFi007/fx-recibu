// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title ITokenMessengerV2
 * @notice Minimal interface for Circle's CCTP TokenMessengerV2.
 *         Only the `depositForBurnWithHook` entry-point is required by CctpDepositForwarder.
 */
interface ITokenMessengerV2 {
    /**
     * @notice Initiates a USDC burn on the source chain and requests a mint on the destination chain,
     *         with an optional hook payload delivered to the mint recipient.
     *
     * @param amount                 Amount of `burnToken` to burn (in token units).
     * @param destinationDomain      CCTP domain ID of the destination chain.
     * @param mintRecipient          Address (as bytes32, left-padded) to receive the minted USDC.
     * @param burnToken              ERC-20 address of the token to burn (USDC on the source chain).
     * @param destinationCaller      Restricts who may call `receiveMessage` on destination (0 = anyone).
     * @param maxFee                 Maximum fee (in token units) the caller is willing to pay.
     * @param minFinalityThreshold   Minimum finality threshold for attestation (1000 = fast, 2000 = standard).
     * @param hookData               Arbitrary bytes forwarded to the hook on the destination chain.
     */
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

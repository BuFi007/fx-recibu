// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MemoConduit, IAddressBook} from "./MemoConduit.sol";
import {CctpConfig} from "./MemoConduitCctpConfig.sol";

/// @title SpokeMemoConduit — one-way DeFi repayment rail, Avalanche spoke -> Arc hub.
/// @notice For factoring / payroll-advance / reimbursement documents financed on the Arc hub
///         (Morpho Midnight). Reuses every MemoConduit check (quorum ERC-3009, live AddressBook,
///         derived nonce, one dispatch per memo, exact-burn accounting) and only narrows routing:
///           mainnet: Avalanche 43114 (CCTP domain 1) -> Arc 5042 (domain 26), USDC (CCTP V2) only
///           testnet analogue: Avalanche Fuji 43113 -> Arc testnet 5042002
///         Checkout keeps using the bidirectional MemoConduit; this contract is a separate deploy.
///
///         The repay is NOT atomic: while the CCTP message is in flight, the Midnight debt on the
///         hub is still open. {RepaymentInitiated} marks it pending; the hub's
///         InvoiceShelf.RepaymentSettled (PR #8) clears it once minted and applied.
contract SpokeMemoConduit is MemoConduit {
    uint32 public constant HUB_CCTP_DOMAIN = 26;

    /// @param advanceId  = BridgePayment.paymentId (quorum-signed)
    /// @param marketId   = BridgePayment.termsHash, the Midnight market id (quorum-signed)
    /// @dev CCTP V2 assigns its nonce off-chain; the CCTP messageHash is keccak256 of the
    ///      MessageSent(message) log CCTP_MESSAGE_TRANSMITTER emits in this same transaction.
    event RepaymentInitiated(
        bytes32 indexed advanceId,
        bytes32 indexed marketId,
        bytes32 indexed memoId,
        address from,
        address recipient,
        uint256 amount,
        uint32 destinationDomain,
        bytes32 bridgeNonce,
        address messageTransmitter
    );

    error NotSpokeToHub(uint256 sourceChainId, uint256 destinationChainId);

    constructor(IAddressBook addressBook_, address[] memory tokens, CctpConfig memory cctp)
        MemoConduit(addressBook_, tokens, cctp)
    {}

    /// @notice the hub chain for the current (spoke) chain, or 0 when this chain is not a spoke.
    function hubOf(uint256 spokeChainId) public pure returns (uint256) {
        if (spokeChainId == 43114) return 5042;
        if (spokeChainId == 43113) return 5042002;
        return 0;
    }

    /// @dev Spoke -> hub, USDC only. Everything else (incl. all CCTPx) is refused before debit.
    function bridgeRouteOf(uint8 protocol, address token, uint256 destinationChainId)
        public
        view
        override
        returns (uint32 sourceDomain, uint32 destinationDomain, address destinationToken, address messenger)
    {
        uint256 hub = hubOf(block.chainid);
        if (hub == 0 || destinationChainId != hub) revert NotSpokeToHub(block.chainid, destinationChainId);
        if (protocol != CCTP_V2_USDC) revert BridgeProtocolNotSupported(protocol);
        (sourceDomain, destinationDomain, destinationToken, messenger) =
            super.bridgeRouteOf(protocol, token, destinationChainId);
        if (destinationDomain != HUB_CCTP_DOMAIN) revert NotSpokeToHub(block.chainid, destinationChainId);
    }

    function _afterCctpBurn(BridgePayment calldata payment, bytes32 nonce, uint32 destinationDomain) internal override {
        emit RepaymentInitiated(
            payment.paymentId,
            payment.termsHash,
            payment.memoId,
            payment.from,
            payment.recipient,
            payment.amount,
            destinationDomain,
            nonce,
            CCTP_MESSAGE_TRANSMITTER
        );
    }
}

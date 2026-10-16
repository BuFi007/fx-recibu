// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {CctpConfig} from "./MemoConduitCctpConfig.sol";

/// @notice Circle ColdStorageAddressBookPlugin read surface (same address on every chain).
interface IAddressBook {
    function getAllowedRecipients(address account) external view returns (address[] memory);
}

/// @dev CCTP v2's exact USDC source API. EURC and cirBTC use CCTPx, not this ABI.
interface IMemoCctpTokenMessengerV2 {
    function localMinter() external view returns (address);
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

interface IMemoCctpTokenMinterV2 {
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

interface IMemoCrossChainTokenService {
    struct QuoteClaim {
        bytes signedQuote;
        address refundAddress;
    }

    function resolveTokenManager(bytes32 tokenId) external view returns (address);
    function isTrustedDomain(uint32 domain) external view returns (bool);
    function paused() external view returns (bool);
    function feeService() external view returns (address);
    function crossChainTransfer(
        bytes32 tokenId,
        uint256 amount,
        uint32 destinationDomain,
        bytes calldata destinationAddress,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        QuoteClaim calldata claim,
        bool autoExecuteHookData,
        bytes calldata hookData
    ) external payable;
}

/// @dev Exact public decoder shape from Circle's IFeeManager. Decoding is not
/// signature verification; CCTS subsequently collects and verifies the same quote.
interface IMemoCctpXFeeManager {
    struct QuoteItem {
        string quoteType;
        bytes32 quoteArgsHash;
        uint256 amount;
    }

    struct Quote {
        QuoteItem[] items;
        uint256 expiry;
        address feeToken;
        uint256 nonce;
        bytes signature;
    }

    function decodeQuote(bytes calldata signedQuote) external view returns (Quote memory);
}

interface IMemoCctpXTokenManager {
    function tokenManagerType() external view returns (uint8);
    function token() external view returns (address);
    function service() external view returns (address);
}

/// @title MemoConduit — one signed authorization, one memo-tagged payment, one transaction.
///
/// A treasury MSCA cannot attach a memo to its own payment: its ColdStorageAddressBook rejects
/// any non-transfer selector, and Arc's `Memo` predeploy only accepts an EOA as the direct
/// caller (it routes through the CallFrom precompile and reverts for contract callers,
/// docs.arc.io/arc/concepts/transaction-memos). So this contract IS the memo rail for
/// smart-account payers: the treasury quorum signs an ERC-3009 `ReceiveWithAuthorization` to
/// this contract, and anyone submits {payWithMemo}:
///   1. the recipient must be on the payer's on-chain allowlist (fail closed),
///   2. the 3009 nonce is DERIVED here from (token, from, recipient, amount, window, memoId,
///      memoData), so the quorum signature commits to the whole payment and the document,
///   3. `receiveWithAuthorization` pulls the funds (bytes overload: ERC-1271 for the MSCA),
///   4. the contract transfers exactly `amount` to `recipient` and emits {MemoConduitPayment},
///      the event desk's webhook verifies (memoId indexed, memo bytes verbatim),
///   5. the contract must end holding exactly what it held before.
/// Any failure reverts everything; the nonce stays unused. No owner or setter: the token
/// set is fixed at deploy. Successful legacy payments now record their existing nonce
/// so this instance cannot also dispatch the same document through its bridge rail.
///
/// The additional {bridgeWithMemo}/{bridgeWithMemoCctpX} entry points use
/// the same quorum and live AddressBook, with asset-specific, typed CCTP/CCTPx calls.
/// They permanently bind one source dispatch per payer/memo, hold no funds afterwards,
/// and emit a source event which is deliberately distinct from a completed payment.
///
/// Sibling of {RecibuMemoRouter} (same deterministic-nonce binding) for plain invoices and
/// reimbursements, which are not on the factoring shelf.
contract MemoConduit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MEMO_PAYMENT_NONCE_TYPEHASH = keccak256(
        "MemoConduitPayment(uint256 chainId,address conduit,address token,address from,address recipient,uint256 amount,uint256 validAfter,uint256 validBefore,bytes32 memoId,bytes32 memoDataHash)"
    );

    IAddressBook public immutable ADDRESS_BOOK;
    mapping(address => bool) public supportedToken;
    mapping(address => mapping(bytes32 => bytes32)) public memoPaymentCommitment;

    /// @notice Bridge rails resolve Circle dependencies per chain (see below). A native token
    /// presence is not proof that CCTP supports it. Each asset has a separate protocol.
    uint8 public constant CCTP_V2_USDC = 1;
    uint8 public constant CCTPX_EURC = 2;
    uint8 public constant CCTPX_CIRBTC = 3;
    uint32 public constant CCTP_STANDARD_FINALITY = 2000;
    /// @dev Circle dependencies are CONSTRUCTOR immutables (see MemoConduitCctpConfig). Routes
    /// stay a reviewed per-chain table below; a zero dependency fails closed.
    address public immutable CCTP_TOKEN_MESSENGER;
    address public immutable CCTP_MESSAGE_TRANSMITTER;
    address public immutable CCTP_TOKEN_MINTER;
    address public immutable CCTPX_SERVICE;
    address public immutable CCTPX_EURC_MANAGER;
    address public immutable CCTPX_CIRBTC_MANAGER;

    /// @notice Hub-and-spoke: Arc 5042 is the hub (Midnight pool, escrow). On mainnet the only
    /// bridge route is the spoke repayment Avalanche 43114 (domain 1) -> Arc 5042 (domain 26).
    uint256 public constant HUB_CHAIN_ID = 5042;
    uint256 public constant SPOKE_CHAIN_ID = 43114;
    uint32 public constant HUB_CCTP_DOMAIN = 26;

    function isMainnetChain(uint256 chainId) public pure returns (bool) {
        return chainId == HUB_CHAIN_ID || chainId == SPOKE_CHAIN_ID;
    }

    function isTestnetChain(uint256 chainId) public pure returns (bool) {
        return chainId == 11155111 || chainId == 84532 || chainId == 43113 || chainId == 5042002;
    }

    bytes32 public constant CCTPX_EURC_TOKEN_ID = 0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd;
    bytes32 public constant CCTPX_CIRBTC_TOKEN_ID = 0x7c27b7b6485f3ea49b7d1a439e288d3c3116f533302afabb7e372dfc0770cc7d;

    struct BridgePayment {
        uint8 protocol;
        address token;
        address from;
        address recipient;
        uint256 amount;
        uint256 destinationChainId;
        uint32 destinationDomain;
        address destinationToken;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 paymentId;
        bytes32 termsHash;
        bytes32 memoId;
        bytes memo;
        bytes32 tokenId;
        bytes32 quoteHash;
        uint256 nativeFee;
        uint256 quoteValidUntil;
    }

    /// @dev No setter, target registry, owner or arbitrary call surface is added.
    /// Every input that can change the source debit or the destination is in the nonce.
    bytes32 public constant BRIDGE_PAYMENT_NONCE_TYPEHASH = keccak256(
        "MemoConduitBridgePayment(uint256 chainId,address conduit,uint8 protocol,address messenger,address token,address from,address recipient,uint256 amount,uint256 destinationChainId,uint32 destinationDomain,address destinationToken,uint256 maxFee,uint32 minFinalityThreshold,uint256 validAfter,uint256 validBefore,bytes32 paymentId,bytes32 termsHash,bytes32 memoId,bytes32 memoHash,bytes32 tokenId,bytes32 quoteHash,uint256 nativeFee,uint256 quoteValidUntil)"
    );

    /// @notice Permanent source commitment, not a statement that the destination was paid.
    /// A fresh authorization/window/paymentId for the same memo cannot burn it again.
    mapping(address => mapping(bytes32 => bytes32)) public bridgePaymentCommitment;

    event MemoConduitSourceBurn(
        bytes32 indexed memoId,
        address indexed from,
        address indexed recipient,
        bytes32 paymentId,
        bytes32 termsHash,
        bytes32 nonce,
        address token,
        uint256 amount,
        uint256 destinationChainId,
        uint32 destinationDomain,
        address destinationToken,
        bytes memo
    );

    /// @notice Spoke side of a NON-ATOMIC hub repayment (USDC CCTP burn). While in flight the
    /// Midnight debt on the hub is still open; accounting marks it pending until the hub's
    /// InvoiceShelf.RepaymentSettled. Convention for advance repayments: `paymentId` = advanceId,
    /// `termsHash` = Midnight marketId (both are inside the quorum-signed nonce). CCTP V2 assigns
    /// its nonce off-chain, so the CCTP messageHash = keccak256(MessageSent.message) emitted by
    /// CCTP_MESSAGE_TRANSMITTER in this same transaction; `bridgeNonce` is this conduit's nonce.
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

    /// @notice One per payment. `memoId` is indexed so a payment is findable by document
    ///         without a transaction hash; `memo` is the exact bytes the quorum signed.
    event MemoConduitPayment(
        bytes32 indexed memoId,
        address indexed from,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes memo
    );

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported(address token);
    error RecipientNotAllowlisted(address from, address recipient);
    error BalanceChanged(uint256 before, uint256 afterPayment);
    error BridgeProtocolNotSupported(uint8 protocol);
    error BridgeRouteNotSupported(uint256 sourceChainId, uint256 destinationChainId, address token);
    error BridgeDestinationMismatch();
    error BridgeFeeOrFinalityNotSupported();
    error BridgeDependencyMismatch();
    error BridgeReferenceMissing();
    error BridgeAlreadyDispatched(address from, bytes32 memoId);
    error BridgeRequiresSmartAccount();
    error BridgeDebitMismatch();
    error BridgeBurnMismatch();
    error BridgeQuoteMismatch();
    error BridgeQuoteExpired();
    error BridgeNativeBalanceChanged();

    constructor(IAddressBook addressBook_, address[] memory tokens, CctpConfig memory cctp) {
        if (address(addressBook_) == address(0)) revert ZeroAddress();
        // a messenger without its minter (or vice versa) is a misconfiguration, not "disabled"
        if ((cctp.tokenMessenger == address(0)) != (cctp.tokenMinter == address(0))) revert ZeroAddress();
        ADDRESS_BOOK = addressBook_;
        CCTP_TOKEN_MESSENGER = cctp.tokenMessenger;
        CCTP_MESSAGE_TRANSMITTER = cctp.messageTransmitter;
        CCTP_TOKEN_MINTER = cctp.tokenMinter;
        CCTPX_SERVICE = cctp.ccts;
        CCTPX_EURC_MANAGER = cctp.eurcManager;
        CCTPX_CIRBTC_MANAGER = cctp.cirbtcManager;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            supportedToken[tokens[i]] = true;
        }
    }

    /// @notice The ERC-3009 nonce the payer must sign for this exact payment.
    function memoPaymentNonceOf(
        address token,
        address from,
        address recipient,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 memoId,
        bytes calldata memoData
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MEMO_PAYMENT_NONCE_TYPEHASH,
                block.chainid,
                address(this),
                token,
                from,
                recipient,
                amount,
                validAfter,
                validBefore,
                memoId,
                keccak256(memoData)
            )
        );
    }

    function payWithMemo(
        address token,
        address from,
        address recipient,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 memoId,
        bytes calldata memoData,
        bytes calldata signature
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (!supportedToken[token]) revert TokenNotSupported(token);
        if (bridgePaymentCommitment[from][memoId] != bytes32(0)) revert BridgeAlreadyDispatched(from, memoId);
        if (!_isAllowlisted(from, recipient)) revert RecipientNotAllowlisted(from, recipient);

        bytes32 nonce = memoPaymentNonceOf(token, from, recipient, amount, validAfter, validBefore, memoId, memoData);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        IERC3009(token).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, signature);
        IERC20(token).safeTransfer(recipient, amount);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert BalanceChanged(balanceBefore, balanceAfter);

        memoPaymentCommitment[from][memoId] = nonce;

        emit MemoConduitPayment(memoId, from, recipient, token, amount, memoData);
    }

    /// @notice Reviewed source/destination facts for the additional bridge rails.
    /// Returned routes are capabilities only; runtime fees, gas coverage and destination
    /// finality must also be verified by BUFI before asking the quorum to sign.
    function bridgeRouteOf(uint8 protocol, address token, uint256 destinationChainId)
        public
        view
        returns (uint32 sourceDomain, uint32 destinationDomain, address destinationToken, address messenger)
    {
        (address sourceToken, uint32 localDomain) = _asset(protocol, block.chainid);
        (address remoteToken, uint32 remoteDomain) = _asset(protocol, destinationChainId);
        if (
            sourceToken == address(0) || remoteToken == address(0) || token != sourceToken
                || block.chainid == destinationChainId || !supportedToken[token]
                || (isMainnetChain(block.chainid)
                    && (block.chainid != SPOKE_CHAIN_ID || destinationChainId != HUB_CHAIN_ID))
        ) revert BridgeRouteNotSupported(block.chainid, destinationChainId, token);
        return (localDomain, remoteDomain, remoteToken, protocol == CCTP_V2_USDC ? CCTP_TOKEN_MESSENGER : CCTPX_SERVICE);
    }

    function bridgeTokenIdOf(uint8 protocol) public pure returns (bytes32) {
        if (protocol == CCTP_V2_USDC) return bytes32(0);
        if (protocol == CCTPX_EURC) return CCTPX_EURC_TOKEN_ID;
        if (protocol == CCTPX_CIRBTC) return CCTPX_CIRBTC_TOKEN_ID;
        revert BridgeProtocolNotSupported(protocol);
    }

    function bridgeTokenManagerOf(uint8 protocol) public view returns (address) {
        if (protocol == CCTP_V2_USDC) return CCTP_TOKEN_MINTER;
        if (protocol == CCTPX_EURC) return CCTPX_EURC_MANAGER;
        if (protocol == CCTPX_CIRBTC) return CCTPX_CIRBTC_MANAGER;
        revert BridgeProtocolNotSupported(protocol);
    }

    function bridgePaymentNonceOf(BridgePayment calldata payment) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                BRIDGE_PAYMENT_NONCE_TYPEHASH,
                block.chainid,
                address(this),
                payment.protocol,
                payment.protocol == CCTP_V2_USDC ? CCTP_TOKEN_MESSENGER : CCTPX_SERVICE,
                payment.token,
                payment.from,
                payment.recipient,
                payment.amount,
                payment.destinationChainId,
                payment.destinationDomain,
                payment.destinationToken,
                payment.maxFee,
                payment.minFinalityThreshold,
                payment.validAfter,
                payment.validBefore,
                payment.paymentId,
                payment.termsHash,
                payment.memoId,
                keccak256(payment.memo),
                payment.tokenId,
                payment.quoteHash,
                payment.nativeFee,
                payment.quoteValidUntil
            )
        );
    }

    /// @notice The existing invoice conduit redeems ONE quorum authorization and burns
    /// the exact USDC debit atomically. The protected Treasury never calls CCTP itself.
    /// The final recipient must still be on its current AddressBook. Destination mint
    /// and settlement are separate: this event must never mark an invoice Paid.
    /// @dev Reverts roll back the 3009 nonce, commitment and debit. After a successful
    /// burn nothing is held here and there is no redirect, refund or fresh-burn retry.
    function bridgeWithMemo(BridgePayment calldata payment, bytes calldata quorumSignature) external nonReentrant {
        if (payment.protocol != CCTP_V2_USDC) revert BridgeProtocolNotSupported(payment.protocol);
        (, uint32 domain, address remoteToken,) =
            bridgeRouteOf(payment.protocol, payment.token, payment.destinationChainId);
        if (payment.destinationDomain != domain || payment.destinationToken != remoteToken) {
            revert BridgeDestinationMismatch();
        }
        if (payment.maxFee != 0 || payment.minFinalityThreshold != CCTP_STANDARD_FINALITY) {
            revert BridgeFeeOrFinalityNotSupported();
        }
        if (
            payment.tokenId != bytes32(0) || payment.quoteHash != bytes32(0) || payment.nativeFee != 0
                || payment.quoteValidUntil != 0
        ) revert BridgeQuoteMismatch();
        _validateBridgePayer(payment);

        IMemoCctpTokenMessengerV2 messenger = IMemoCctpTokenMessengerV2(CCTP_TOKEN_MESSENGER);
        if (
            CCTP_TOKEN_MESSENGER.code.length == 0 || CCTP_TOKEN_MINTER.code.length == 0
                || messenger.localMinter() != CCTP_TOKEN_MINTER
                || messenger.remoteTokenMessengers(domain) != bytes32(uint256(uint160(CCTP_TOKEN_MESSENGER)))
                || IMemoCctpTokenMinterV2(CCTP_TOKEN_MINTER).burnLimitsPerMessage(payment.token) < payment.amount
        ) revert BridgeDependencyMismatch();

        bytes32 nonce = bridgePaymentNonceOf(payment);
        bridgePaymentCommitment[payment.from][payment.memoId] = nonce;
        IERC20 token = IERC20(payment.token);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 treasuryBefore = token.balanceOf(payment.from);
        uint256 supplyBefore = token.totalSupply();
        IERC3009(payment.token)
            .receiveWithAuthorization(
                payment.from,
                address(this),
                payment.amount,
                payment.validAfter,
                payment.validBefore,
                nonce,
                quorumSignature
            );
        if (
            token.balanceOf(address(this)) != balanceBefore + payment.amount
                || token.balanceOf(payment.from) != treasuryBefore - payment.amount
        ) revert BridgeDebitMismatch();

        token.forceApprove(CCTP_TOKEN_MESSENGER, payment.amount);
        messenger.depositForBurn(
            payment.amount,
            domain,
            bytes32(uint256(uint160(payment.recipient))),
            payment.token,
            bytes32(0),
            0,
            CCTP_STANDARD_FINALITY
        );
        token.forceApprove(CCTP_TOKEN_MESSENGER, 0);
        if (
            token.balanceOf(address(this)) != balanceBefore || token.totalSupply() != supplyBefore - payment.amount
                || token.balanceOf(payment.from) != treasuryBefore - payment.amount
        ) revert BridgeBurnMismatch();

        _emitSourceBurn(payment, nonce);
        emit RepaymentInitiated(
            payment.paymentId,
            payment.termsHash,
            payment.memoId,
            payment.from,
            payment.recipient,
            payment.amount,
            domain,
            nonce,
            CCTP_MESSAGE_TRANSMITTER
        );
    }

    /// @notice Native-fee CCTPx transfer, preserving the very same quorum and live
    /// recipient check. Native fees come from the submitting relayer, never an extra
    /// token debit from the Treasury. The opaque signed quote is forwarded verbatim:
    /// Circle's FeeManager validates its signature, fee channel and real timestamp or
    /// block expiry. quoteValidUntil is an additional conservative wall-clock bound.
    function bridgeWithMemoCctpX(
        BridgePayment calldata payment,
        bytes calldata signedQuote,
        bytes calldata quorumSignature
    ) external payable nonReentrant {
        if (payment.protocol != CCTPX_EURC && payment.protocol != CCTPX_CIRBTC) {
            revert BridgeProtocolNotSupported(payment.protocol);
        }
        (, uint32 domain, address remoteToken,) =
            bridgeRouteOf(payment.protocol, payment.token, payment.destinationChainId);
        if (payment.destinationDomain != domain || payment.destinationToken != remoteToken) {
            revert BridgeDestinationMismatch();
        }
        if (payment.maxFee != 0 || payment.minFinalityThreshold != CCTP_STANDARD_FINALITY) {
            revert BridgeFeeOrFinalityNotSupported();
        }
        if (
            payment.tokenId != bridgeTokenIdOf(payment.protocol) || signedQuote.length < 2 || signedQuote[0] != 0x01
                || payment.quoteHash != keccak256(signedQuote) || payment.nativeFee != msg.value
                || payment.quoteValidUntil == 0 || payment.validBefore > payment.quoteValidUntil
        ) revert BridgeQuoteMismatch();
        if (block.timestamp >= payment.quoteValidUntil) revert BridgeQuoteExpired();
        _validateBridgePayer(payment);

        address managerAddress = bridgeTokenManagerOf(payment.protocol);
        IMemoCrossChainTokenService service = IMemoCrossChainTokenService(CCTPX_SERVICE);
        IMemoCctpXTokenManager manager = IMemoCctpXTokenManager(managerAddress);
        if (
            CCTPX_SERVICE.code.length == 0 || managerAddress.code.length == 0 || service.paused()
                || !service.isTrustedDomain(domain) || service.resolveTokenManager(payment.tokenId) != managerAddress
                || manager.tokenManagerType() != 1 || manager.token() != payment.token
                || manager.service() != CCTPX_SERVICE
        ) revert BridgeDependencyMismatch();
        _validateNativeQuote(service.feeService(), payment, signedQuote);

        bytes32 nonce = bridgePaymentNonceOf(payment);
        bridgePaymentCommitment[payment.from][payment.memoId] = nonce;
        IERC20 token = IERC20(payment.token);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 treasuryBefore = token.balanceOf(payment.from);
        uint256 supplyBefore = token.totalSupply();
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        IERC3009(payment.token)
            .receiveWithAuthorization(
                payment.from,
                address(this),
                payment.amount,
                payment.validAfter,
                payment.validBefore,
                nonce,
                quorumSignature
            );
        if (
            token.balanceOf(address(this)) != balanceBefore + payment.amount
                || token.balanceOf(payment.from) != treasuryBefore - payment.amount
        ) revert BridgeDebitMismatch();

        // CCTPx pulls through its registered asset-specific TokenManager, not CCTS.
        token.forceApprove(managerAddress, payment.amount);
        service.crossChainTransfer{value: payment.nativeFee}(
            payment.tokenId,
            payment.amount,
            domain,
            abi.encodePacked(payment.recipient),
            bytes32(0),
            CCTP_STANDARD_FINALITY,
            IMemoCrossChainTokenService.QuoteClaim({signedQuote: signedQuote, refundAddress: payment.from}),
            false,
            bytes("")
        );
        token.forceApprove(managerAddress, 0);
        if (
            token.balanceOf(address(this)) != balanceBefore || token.totalSupply() != supplyBefore - payment.amount
                || token.balanceOf(payment.from) != treasuryBefore - payment.amount
        ) revert BridgeBurnMismatch();
        if (address(this).balance != nativeBalanceBefore) revert BridgeNativeBalanceChanged();
        _emitSourceBurn(payment, nonce);
    }

    function _validateBridgePayer(BridgePayment calldata payment) private view {
        if (payment.amount == 0) revert ZeroAmount();
        if (payment.recipient == address(0) || payment.from == address(0)) revert ZeroAddress();
        if (payment.from.code.length == 0) revert BridgeRequiresSmartAccount();
        if (IERC20Metadata(payment.token).decimals() != (payment.protocol == CCTPX_CIRBTC ? 8 : 6)) {
            revert BridgeDependencyMismatch();
        }
        if (payment.paymentId == bytes32(0) || payment.termsHash == bytes32(0) || payment.memoId == bytes32(0)) {
            revert BridgeReferenceMissing();
        }
        if (
            bridgePaymentCommitment[payment.from][payment.memoId] != bytes32(0)
                || memoPaymentCommitment[payment.from][payment.memoId] != bytes32(0)
        ) revert BridgeAlreadyDispatched(payment.from, payment.memoId);
        if (!_isAllowlisted(payment.from, payment.recipient)) {
            revert RecipientNotAllowlisted(payment.from, payment.recipient);
        }
    }

    function _validateNativeQuote(address feeManager, BridgePayment calldata payment, bytes calldata signedQuote)
        private
        view
    {
        if (feeManager.code.length == 0) revert BridgeDependencyMismatch();
        IMemoCctpXFeeManager.Quote memory quote = IMemoCctpXFeeManager(feeManager).decodeQuote(signedQuote);
        // Circle's standard transfer requires FORWARD and PROTOCOL. PRE_FINALITY
        // belongs to the fast rail and must be absent. No ERC-20 fee approval.
        if (quote.feeToken != address(0) || quote.items.length != 2 || quote.signature.length == 0) {
            revert BridgeQuoteMismatch();
        }
        bytes32 first = keccak256(bytes(quote.items[0].quoteType));
        bytes32 second = keccak256(bytes(quote.items[1].quoteType));
        if (
            !((first == keccak256("FORWARD") && second == keccak256("PROTOCOL"))
                    || (first == keccak256("PROTOCOL") && second == keccak256("FORWARD")))
                || quote.items[0].amount + quote.items[1].amount != payment.nativeFee
        ) revert BridgeQuoteMismatch();
        uint8 mode = uint8(quote.expiry >> 248);
        uint256 deadline = quote.expiry & ((uint256(1) << 248) - 1);
        if (mode == 0) {
            if (payment.quoteValidUntil != deadline) revert BridgeQuoteMismatch();
            if (block.timestamp > deadline) revert BridgeQuoteExpired();
        } else if (mode == 1) {
            if (block.number > deadline) revert BridgeQuoteExpired();
        } else {
            revert BridgeQuoteMismatch();
        }
    }

    function _emitSourceBurn(BridgePayment calldata payment, bytes32 nonce) private {
        emit MemoConduitSourceBurn(
            payment.memoId,
            payment.from,
            payment.recipient,
            payment.paymentId,
            payment.termsHash,
            nonce,
            payment.token,
            payment.amount,
            payment.destinationChainId,
            payment.destinationDomain,
            payment.destinationToken,
            payment.memo
        );
    }

    /// @dev Routes never cross environments: a mainnet source only resolves mainnet
    /// destinations and a testnet source only testnet ones.
    function _asset(uint8 protocol, uint256 chainId) private view returns (address token, uint32 domain) {
        if (isMainnetChain(block.chainid)) return _mainnetAsset(protocol, chainId);
        if (isTestnetChain(block.chainid)) return _testnetAsset(protocol, chainId);
        if (protocol < CCTP_V2_USDC || protocol > CCTPX_CIRBTC) revert BridgeProtocolNotSupported(protocol);
        return (address(0), 0);
    }

    /// @dev Mainnet asset table: CCTP V2 USDC on Arc (domain 26) and Avalanche (domain 1);
    /// remoteTokenMessengers verified both ways on 2026-10-16. bridgeRouteOf further limits
    /// mainnet to the spoke->hub direction. Mainnet CCTPx is not routed.
    function _mainnetAsset(uint8 protocol, uint256 chainId) private pure returns (address token, uint32 domain) {
        if (protocol == CCTP_V2_USDC) {
            if (chainId == 5042) return (0x3600000000000000000000000000000000000000, 26);
            if (chainId == 43114) return (0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, 1);
            return (address(0), 0);
        }
        if (protocol == CCTPX_EURC || protocol == CCTPX_CIRBTC) return (address(0), 0);
        revert BridgeProtocolNotSupported(protocol);
    }

    function _testnetAsset(uint8 protocol, uint256 chainId) private pure returns (address token, uint32 domain) {
        if (protocol == CCTP_V2_USDC) return _testnetUsdc(chainId);
        if (protocol == CCTPX_EURC) {
            if (chainId == 11155111) return (0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4, 0);
            if (chainId == 84532) return (0x808456652fdb597867f38412077A9182bf77359F, 6);
            if (chainId == 43113) return (0x5E44db7996c682E92a960b65AC713a54AD815c6B, 1);
            if (chainId == 5042002) return (0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a, 26);
            return (address(0), 0);
        }
        if (protocol == CCTPX_CIRBTC) {
            if (chainId == 11155111) return (0x3a3fe695F684Bf9b9e43CF43C2b895Ea5e392bB3, 0);
            if (chainId == 5042002) return (0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF, 26);
            return (address(0), 0);
        }
        revert BridgeProtocolNotSupported(protocol);
    }

    function _testnetUsdc(uint256 chainId) private pure returns (address token, uint32 domain) {
        if (chainId == 84532) return (0x036CbD53842c5426634e7929541eC2318f3dCF7e, 6);
        if (chainId == 43113) return (0x5425890298aed601595a70AB815c96711a31Bc65, 1);
        if (chainId == 5042002) return (0x3600000000000000000000000000000000000000, 26);
        return (address(0), 0);
    }

    /// @dev Bounded by the payer's own allowlist size. An account without the plugin reads
    ///      an empty list, so it can never pay through here (fail closed).
    function _isAllowlisted(address from, address recipient) internal view returns (bool) {
        address[] memory allowed = ADDRESS_BOOK.getAllowedRecipients(from);
        for (uint256 i; i < allowed.length; ++i) {
            if (allowed[i] == recipient) return true;
        }
        return false;
    }
}

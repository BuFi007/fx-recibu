// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {
    MemoConduit,
    IAddressBook,
    IMemoCrossChainTokenService,
    IMemoCctpXFeeManager
} from "../../src/rails/MemoConduit.sol";
import {BridgeBookMock, BridgeQuorumMock} from "./MemoConduitCctp.t.sol";

/// @dev Asset-specific EIP-712 names and six/eight-decimal token atomic units.
contract CctpXTokenMock is ERC20 {
    uint8 private immutable precision;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    error InvalidSignature();
    error AuthorizationUnavailable();

    constructor(string memory name_, string memory symbol_, uint8 precision_) ERC20(name_, symbol_) {
        precision = precision_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name_)),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        if (
            msg.sender != to || authorizationState[from][nonce] || block.timestamp <= validAfter
                || block.timestamp >= validBefore
        ) revert AuthorizationUnavailable();
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }
}

contract CctpXManagerMock {
    address public token;
    address public service;
    uint8 public tokenManagerType;
    uint8 public burnMode;

    function configure(address token_, address service_, uint8 type_) external {
        token = token_;
        service = service_;
        tokenManagerType = type_;
    }

    function setBurnMode(uint8 mode) external {
        burnMode = mode;
    }

    function takeToken(address from, uint256 amount) external {
        require(msg.sender == service, "service only");
        IERC20(token).transferFrom(from, address(this), amount);
        if (burnMode == 1) return;
        CctpXTokenMock(token).burn(address(this), burnMode == 2 ? amount - 1 : amount);
    }
}

contract CctpXFeeMock is IMemoCctpXFeeManager {
    function decodeQuote(bytes calldata signedQuote) public pure returns (Quote memory) {
        require(signedQuote.length > 1 && signedQuote[0] == 0x01, "bad wire version");
        return abi.decode(signedQuote[1:], (Quote));
    }
}

contract CctpXServiceMock is IMemoCrossChainTokenService {
    using Strings for uint256;
    address public feeService;
    bool public paused;
    bool public invalidCircleSignature;
    mapping(uint32 => bool) public isTrustedDomain;
    mapping(bytes32 => address) public resolveTokenManager;
    uint256 public calls;
    uint256 public lastFee;
    bytes32 public lastTokenId;
    uint256 public lastAmount;
    bytes public lastRecipient;
    address public lastRefundAddress;
    bool public lastAutoExecute;
    bytes public lastHook;
    bytes public callback;
    address public callbackTarget;
    bool public callbackSucceeded;

    function configure(address fee, bytes32 tokenId, address manager) external {
        feeService = fee;
        resolveTokenManager[tokenId] = manager;
        isTrustedDomain[0] = true;
        isTrustedDomain[1] = true;
        isTrustedDomain[6] = true;
        isTrustedDomain[26] = true;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setTrusted(uint32 domain, bool value) external {
        isTrustedDomain[domain] = value;
    }

    function setInvalidCircleSignature(bool value) external {
        invalidCircleSignature = value;
    }

    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callback = data;
    }

    function forwardArgsHash(uint32 destinationDomain, bytes memory destinationAddress) public pure returns (bytes32) {
        string[] memory args = new string[](6);
        args[0] = uint256(destinationDomain).toString();
        args[1] = "TransferMessage";
        args[2] = Strings.toHexString(abi.encodePacked(bytes32(0)));
        args[3] = "false";
        args[4] = "";
        args[5] = Strings.toHexString(destinationAddress);
        return keccak256(abi.encode(args));
    }

    function protocolArgsHash(bytes32 tokenId) public pure returns (bytes32) {
        string[] memory args = new string[](1);
        args[0] = Strings.toHexString(abi.encodePacked(tokenId));
        return keccak256(abi.encode(args));
    }

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
    ) external payable {
        require(!paused && !invalidCircleSignature, "Circle quote rejected");
        require(destinationCaller == bytes32(0) && minFinalityThreshold == 2000, "bad caller/finality");
        require(destinationAddress.length == 20 && !autoExecuteHookData && hookData.length == 0, "bad recipient/hook");
        IMemoCctpXFeeManager.Quote memory quote = IMemoCctpXFeeManager(feeService).decodeQuote(claim.signedQuote);
        require(quote.feeToken == address(0), "fee token not native");
        uint256 total;
        for (uint256 i; i < quote.items.length; ++i) {
            total += quote.items[i].amount;
            if (keccak256(bytes(quote.items[i].quoteType)) == keccak256("FORWARD")) {
                require(
                    quote.items[i].quoteArgsHash == forwardArgsHash(destinationDomain, destinationAddress),
                    "bad forward args"
                );
            } else {
                require(quote.items[i].quoteArgsHash == protocolArgsHash(tokenId), "bad protocol args");
            }
        }
        require(total == msg.value, "bad quoted fee");
        calls += 1;
        lastFee = msg.value;
        lastTokenId = tokenId;
        lastAmount = amount;
        lastRecipient = destinationAddress;
        lastRefundAddress = claim.refundAddress;
        lastAutoExecute = autoExecuteHookData;
        lastHook = hookData;
        if (callbackTarget != address(0)) (callbackSucceeded,) = callbackTarget.call(callback);
        CctpXManagerMock(resolveTokenManager[tokenId]).takeToken(msg.sender, amount);
    }
}

contract MemoConduitCctpXTest is Test {
    uint256 constant KEY_ONE = 0xA11CE;
    uint256 constant KEY_TWO = 0xB0B;
    uint256 constant FEE = 2_000_000_000_000;
    address constant EURC = 0x808456652fdb597867f38412077A9182bf77359F;
    address constant SERVICE = 0x63753E722bd2C2A5DF6EE19C5106662208B81077;
    address constant EURC_MANAGER = 0xE5D6eacf2eD5A7F81cC89d2a216F004092c0C2E0;
    bytes32 constant EURC_ID = 0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd;
    address constant CIRBTC = 0x3a3fe695F684Bf9b9e43CF43C2b895Ea5e392bB3;
    address constant CIRBTC_MANAGER = 0xb995F4060c38b7608626d0CCaBE547cdc2c7390A;
    bytes32 constant CIRBTC_ID = 0x7c27b7b6485f3ea49b7d1a439e288d3c3116f533302afabb7e372dfc0770cc7d;
    bytes32 constant MEMO_ID = keccak256("invoice:cctpx:0");
    uint256 constant BALANCE = 10_000e6;

    MemoConduit conduit;
    CctpXTokenMock token;
    BridgeBookMock book;
    BridgeQuorumMock treasury;
    CctpXServiceMock service;
    CctpXManagerMock manager;
    CctpXFeeMock feeManager;
    address recipient;

    function setUp() public {
        vm.chainId(84532);
        vm.warp(1_780_000_000);
        vm.roll(100);
        vm.deal(address(this), 1 ether);
        _configureToken(EURC, EURC_MANAGER, EURC_ID, "EURC", "EURC", 6);
    }

    function _configureToken(
        address tokenAddress,
        address managerAddress,
        bytes32 tokenId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 precision
    ) internal {
        deployCodeTo(
            "MemoConduitCctpX.t.sol:CctpXTokenMock", abi.encode(tokenName, tokenSymbol, precision), tokenAddress
        );
        deployCodeTo("MemoConduitCctpX.t.sol:CctpXManagerMock", managerAddress);
        deployCodeTo("MemoConduitCctpX.t.sol:CctpXServiceMock", SERVICE);
        token = CctpXTokenMock(tokenAddress);
        manager = CctpXManagerMock(managerAddress);
        service = CctpXServiceMock(SERVICE);
        feeManager = new CctpXFeeMock();
        manager.configure(tokenAddress, SERVICE, 1);
        service.configure(address(feeManager), tokenId, managerAddress);
        book = new BridgeBookMock();
        treasury = new BridgeQuorumMock(vm.addr(KEY_ONE), vm.addr(KEY_TWO));
        address[] memory tokens = new address[](1);
        tokens[0] = tokenAddress;
        conduit = new MemoConduit(IAddressBook(address(book)), tokens);
        recipient = makeAddr("foreign exact recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        book.set(recipients);
        token.mint(address(treasury), BALANCE);
    }

    function payment() internal view returns (MemoConduit.BridgePayment memory) {
        return MemoConduit.BridgePayment({
            protocol: 2,
            token: address(token),
            from: address(treasury),
            recipient: recipient,
            amount: 1e6,
            destinationChainId: 5042002,
            destinationDomain: 26,
            destinationToken: 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("original cctpx source leg"),
            termsHash: keccak256("accepted EURC terms"),
            memoId: MEMO_ID,
            memo: bytes("invoice:cctpx:0"),
            tokenId: EURC_ID,
            quoteHash: bytes32(0),
            nativeFee: FEE,
            quoteValidUntil: block.timestamp + 1 hours
        });
    }

    function quoteOf(MemoConduit.BridgePayment memory p, uint256 expiry)
        internal
        view
        returns (IMemoCctpXFeeManager.Quote memory quote)
    {
        IMemoCctpXFeeManager.QuoteItem[] memory items = new IMemoCctpXFeeManager.QuoteItem[](2);
        items[0] = IMemoCctpXFeeManager.QuoteItem(
            "FORWARD", service.forwardArgsHash(p.destinationDomain, abi.encodePacked(p.recipient)), FEE - 7
        );
        items[1] = IMemoCctpXFeeManager.QuoteItem("PROTOCOL", service.protocolArgsHash(p.tokenId), 7);
        return IMemoCctpXFeeManager.Quote(items, expiry, address(0), 42, hex"abcdef");
    }

    function wire(IMemoCctpXFeeManager.Quote memory quote) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), abi.encode(quote));
    }

    function sign(MemoConduit.BridgePayment memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.from,
                address(conduit),
                p.amount,
                p.validAfter,
                p.validBefore,
                conduit.bridgePaymentNonceOf(p)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY_ONE, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY_TWO, digest);
        return abi.encode(abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    function original()
        internal
        view
        returns (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory signature)
    {
        p = payment();
        signedQuote = wire(quoteOf(p, p.quoteValidUntil));
        p.quoteHash = keccak256(signedQuote);
        signature = sign(p);
    }

    function unchanged(MemoConduit.BridgePayment memory p) internal view {
        assertEq(token.balanceOf(address(treasury)), BALANCE);
        assertEq(token.balanceOf(address(conduit)), 0);
        assertEq(token.allowance(address(conduit), address(manager)), 0);
        assertEq(token.allowance(address(conduit), SERVICE), 0);
        assertEq(address(conduit).balance, 0);
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), bytes32(0));
        assertFalse(token.authorizationState(p.from, conduit.bridgePaymentNonceOf(p)));
        assertEq(service.calls(), 0);
    }

    function test_eurcNativeFeeExactBurnAndPackedRecipientWithoutHooks() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        uint256 relayerBalance = address(this).balance;
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertEq(address(this).balance, relayerBalance - FEE);
        assertEq(address(conduit).balance, 0);
        assertEq(token.balanceOf(address(treasury)), BALANCE - p.amount);
        assertEq(token.totalSupply(), BALANCE - p.amount);
        assertEq(token.balanceOf(address(conduit)), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.allowance(address(conduit), address(manager)), 0);
        assertEq(token.allowance(address(conduit), SERVICE), 0);
        assertEq(service.lastRecipient(), abi.encodePacked(recipient));
        assertEq(service.lastRecipient().length, 20);
        assertEq(service.lastRefundAddress(), address(treasury));
        assertEq(service.lastTokenId(), EURC_ID);
        assertEq(service.lastAmount(), 1e6);
        assertEq(service.lastFee(), FEE);
        assertFalse(service.lastAutoExecute());
        assertEq(service.lastHook().length, 0);
    }

    function test_cirbtcSepoliaArcEightDecimalAmountNotUsdcConversion() public {
        vm.chainId(11155111);
        _configureToken(CIRBTC, CIRBTC_MANAGER, CIRBTC_ID, "Circle Wrapped Bitcoin", "cirBTC", 8);
        MemoConduit.BridgePayment memory p = payment();
        p.protocol = 3;
        p.tokenId = CIRBTC_ID;
        p.destinationToken = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
        p.amount = 1_000_000; // 0.01 cirBTC, no USD/stablecoin conversion
        bytes memory signedQuote = wire(quoteOf(p, p.quoteValidUntil));
        p.quoteHash = keccak256(signedQuote);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sign(p));
        assertEq(token.decimals(), 8);
        assertEq(service.lastAmount(), p.amount);
        assertEq(token.totalSupply(), BALANCE - p.amount);
        assertEq(token.allowance(address(conduit), CIRBTC_MANAGER), 0);
    }

    function test_cirbtcCannotInventBaseOrFujiRoute() public {
        vm.chainId(11155111);
        _configureToken(CIRBTC, CIRBTC_MANAGER, CIRBTC_ID, "Circle Wrapped Bitcoin", "cirBTC", 8);
        MemoConduit.BridgePayment memory p = payment();
        p.protocol = 3;
        p.tokenId = CIRBTC_ID;
        for (uint256 i; i < 2; ++i) {
            p.destinationChainId = i == 0 ? 84532 : 43113;
            vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
            conduit.bridgeWithMemoCctpX{value: FEE}(p, hex"0100", "");
            unchanged(p);
        }
    }

    function test_assetPrecisionMustMatchVerifiedCapabilityBeforeDebit() public {
        _configureToken(EURC, EURC_MANAGER, EURC_ID, "EURC", "EURC", 8);
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_quoteChangedRepricedOrNativeFeeMismatchFailsBeforeDebit() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        IMemoCctpXFeeManager.Quote memory quote = quoteOf(p, p.quoteValidUntil);
        quote.nonce += 1;
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, wire(quote), sig);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE + 1}(p, signedQuote, sig);
        vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE - 1}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_allQuoteFieldsAreSignedByQuorum() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        IMemoCctpXFeeManager.Quote memory quote = quoteOf(p, p.quoteValidUntil);
        quote.items[0].amount += 1;
        signedQuote = wire(quote);
        p.nativeFee += 1;
        p.quoteHash = keccak256(signedQuote);
        vm.expectRevert(CctpXTokenMock.InvalidSignature.selector);
        conduit.bridgeWithMemoCctpX{value: p.nativeFee}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_quoteTimestampAndBlockExpiryAreActuallyEnforced() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        vm.warp(p.quoteValidUntil);
        vm.expectRevert(MemoConduit.BridgeQuoteExpired.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        vm.warp(p.validAfter + 1);
        signedQuote = wire(quoteOf(p, (uint256(1) << 248) | 100));
        p.quoteHash = keccak256(signedQuote);
        sig = sign(p);
        vm.roll(101);
        vm.expectRevert(MemoConduit.BridgeQuoteExpired.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_blockExpiryValidNowAndTimestampConservativeLimit() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory signedQuote = wire(quoteOf(p, (uint256(1) << 248) | 100));
        p.quoteHash = keccak256(signedQuote);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sign(p));
        assertEq(service.calls(), 1);
    }

    function test_quoteWrongNativeChannelUnknownDuplicateOrFastItemFailsBeforeDebit() public {
        for (uint256 i; i < 6; ++i) {
            MemoConduit.BridgePayment memory p = payment();
            IMemoCctpXFeeManager.Quote memory quote = quoteOf(p, p.quoteValidUntil);
            if (i == 0) quote.feeToken = EURC;
            if (i == 1) quote.items[1].quoteType = "FORWARD";
            if (i == 2) quote.items[1].quoteType = "PRE_FINALITY";
            if (i == 3) quote.items[1].quoteType = "UNKNOWN";
            if (i == 4) quote.expiry = (uint256(2) << 248) | p.quoteValidUntil;
            if (i == 5) quote.items[0].amount += 1;
            bytes memory signedQuote = wire(quote);
            p.quoteHash = keccak256(signedQuote);
            vm.expectRevert(MemoConduit.BridgeQuoteMismatch.selector);
            conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, "");
            unchanged(p);
        }
    }

    function test_circleSignatureOrQuoteArgsRejectionRestoresOriginalNonceAndDebit() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        service.setInvalidCircleSignature(true);
        vm.expectRevert(bytes("Circle quote rejected"));
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
        service.setInvalidCircleSignature(false);
        IMemoCctpXFeeManager.Quote memory quote = quoteOf(p, p.quoteValidUntil);
        quote.items[0].quoteArgsHash = keccak256("different approved recipient");
        signedQuote = wire(quote);
        p.quoteHash = keccak256(signedQuote);
        sig = sign(p);
        vm.expectRevert(bytes("bad forward args"));
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_managerSwappedTokenServiceOrLockModeFailsBeforeDebit() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        for (uint256 i; i < 3; ++i) {
            manager.configure(i == 0 ? makeAddr("fake token") : EURC, i == 1 ? address(this) : SERVICE, i == 2 ? 2 : 1);
            vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
            conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
            unchanged(p);
        }
    }

    function test_pausedServiceOrRetiredDomainFailsClosed() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        service.setPaused(true);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        service.setPaused(false);
        service.setTrusted(26, false);
        vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_lockOrShortBurnIsNeverMislabelledAsSourceBurn() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        for (uint8 i = 1; i <= 2; ++i) {
            manager.setBurnMode(i);
            vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
            conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
            unchanged(p);
        }
    }

    function test_revokedRecipientOrIncompleteQuorumCannotUseCctpX() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        (bytes memory one,) = abi.decode(sig, (bytes, bytes));
        vm.expectRevert(CctpXTokenMock.InvalidSignature.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, abi.encode(one, one));
        book.set(new address[](0));
        vm.expectPartialRevert(MemoConduit.RecipientNotAllowlisted.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        unchanged(p);
    }

    function test_reentrantReplayAndUncertainFreshWindowCannotDuplicateSource() public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote, bytes memory sig) = original();
        service.setCallback(address(conduit), abi.encodeCall(conduit.bridgeWithMemoCctpX, (p, signedQuote, sig)));
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertFalse(service.callbackSucceeded());
        assertEq(service.calls(), 1);
        bytes32 committed = conduit.bridgePaymentCommitment(p.from, p.memoId);
        p.paymentId = keccak256("must never create a new source leg");
        p.validBefore -= 1;
        sig = sign(p);
        vm.expectPartialRevert(MemoConduit.BridgeAlreadyDispatched.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertEq(service.calls(), 1);
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), committed);
    }

    function testFuzz_eurcNoSilentPrincipalOrNativeFeeRecotation(uint64 rawAmount) public {
        (MemoConduit.BridgePayment memory p, bytes memory signedQuote,) = original();
        p.amount = bound(uint256(rawAmount), 1, BALANCE);
        bytes memory sig = sign(p);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertEq(token.balanceOf(address(treasury)), BALANCE - p.amount);
        assertEq(token.totalSupply(), BALANCE - p.amount);
        assertEq(service.lastAmount(), p.amount);
        assertEq(service.lastFee(), FEE);
    }

    function testFuzz_cirbtcAtomicUnitsAndOriginalReplay(uint64 rawAmount) public {
        vm.chainId(11155111);
        _configureToken(CIRBTC, CIRBTC_MANAGER, CIRBTC_ID, "Circle Wrapped Bitcoin", "cirBTC", 8);
        MemoConduit.BridgePayment memory p = payment();
        p.protocol = 3;
        p.tokenId = CIRBTC_ID;
        p.destinationToken = 0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF;
        p.amount = bound(uint256(rawAmount), 1, BALANCE);
        bytes memory signedQuote = wire(quoteOf(p, p.quoteValidUntil));
        p.quoteHash = keccak256(signedQuote);
        bytes memory sig = sign(p);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertEq(token.decimals(), 8);
        assertEq(token.balanceOf(address(treasury)), BALANCE - p.amount);
        assertEq(token.totalSupply(), BALANCE - p.amount);
        assertEq(service.lastAmount(), p.amount);
        vm.expectPartialRevert(MemoConduit.BridgeAlreadyDispatched.selector);
        conduit.bridgeWithMemoCctpX{value: FEE}(p, signedQuote, sig);
        assertEq(service.calls(), 1);
    }
}

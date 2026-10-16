// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MemoConduitCctpConfig, CctpConfig} from "../../src/rails/MemoConduitCctpConfig.sol";
import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MemoConduit, IAddressBook} from "../../src/rails/MemoConduit.sol";
import {MockArcUSDC} from "../mocks/MockMemoConduitStack.sol";
import {MockUSDC3009} from "../mocks/MockUSDC3009.sol";

contract BridgeUsdcMock is MockArcUSDC {
    bool public shortDebit;

    function setShortDebit(bool value) external {
        shortDebit = value;
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        // An authorization token which under-delivers must not get as far as CCTP.
        if (shortDebit && from != address(0) && to != address(0)) value -= 1;
        super._update(from, to, value);
    }
}

contract BridgeBookMock {
    address[] private recipients;
    bool public unavailable;

    function set(address[] memory values) external {
        recipients = values;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function getAllowedRecipients(address) external view returns (address[] memory) {
        require(!unavailable, "book unavailable");
        return recipients;
    }
}

/// @dev Genuine two-signature ERC-1271 check; one signer cannot redeem the Treasury.
contract BridgeQuorumMock is IERC1271 {
    address public immutable signerOne;
    address public immutable signerTwo;

    constructor(address one, address two) {
        signerOne = one;
        signerTwo = two;
    }

    function isValidSignature(bytes32 digest, bytes memory quorumSignature) external view returns (bytes4) {
        (bytes memory one, bytes memory two) = abi.decode(quorumSignature, (bytes, bytes));
        (address first, ECDSA.RecoverError e1,) = ECDSA.tryRecover(digest, one);
        (address second, ECDSA.RecoverError e2,) = ECDSA.tryRecover(digest, two);
        return e1 == ECDSA.RecoverError.NoError && e2 == ECDSA.RecoverError.NoError && first == signerOne
            && second == signerTwo
            ? IERC1271.isValidSignature.selector
            : bytes4(0);
    }
}

contract BridgeMinterMock {
    mapping(address => uint256) public burnLimitsPerMessage;

    function setLimit(address token, uint256 limit) external {
        burnLimitsPerMessage[token] = limit;
    }

    function burn(address token, uint256 amount) external {
        require(msg.sender == 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA, "messenger only");
        BridgeUsdcMock(token).burn(address(this), amount);
    }
}

contract BridgeMessengerMock {
    address public localMinter;
    mapping(uint32 => bytes32) public remoteTokenMessengers;
    uint256 public calls;
    uint8 public mode;
    uint32 public lastDomain;
    bytes32 public lastRecipient;
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastCaller;
    uint256 public lastFee;
    uint32 public lastFinality;
    bytes public callback;
    address public callbackTarget;
    bool public callbackSucceeded;

    function configure(address minter) external {
        localMinter = minter;
        remoteTokenMessengers[1] = bytes32(uint256(uint160(address(this))));
        remoteTokenMessengers[6] = bytes32(uint256(uint160(address(this))));
        remoteTokenMessengers[26] = bytes32(uint256(uint160(address(this))));
    }

    function setRemote(uint32 domain, bytes32 messenger) external {
        remoteTokenMessengers[domain] = messenger;
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callback = data;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(mode != 1, "messenger unavailable");
        calls += 1;
        lastDomain = destinationDomain;
        lastRecipient = mintRecipient;
        lastToken = burnToken;
        lastAmount = amount;
        lastCaller = destinationCaller;
        lastFee = maxFee;
        lastFinality = minFinalityThreshold;
        if (callbackTarget != address(0)) {
            (callbackSucceeded,) = callbackTarget.call(callback);
        }
        if (mode == 2) return; // no pull and no burn
        IERC20(burnToken).transferFrom(msg.sender, localMinter, mode == 3 ? amount - 1 : amount);
        if (mode == 4) return; // transfer is not a burn
        BridgeMinterMock(localMinter).burn(burnToken, mode == 3 || mode == 5 ? amount - 1 : amount);
    }
}

contract MemoConduitCctpTest is Test {
    uint256 constant SOURCE_CHAIN = 84532;
    uint256 constant DESTINATION_CHAIN = 5042002;
    address constant SOURCE_TOKEN = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant DESTINATION_TOKEN = 0x3600000000000000000000000000000000000000;
    address constant MESSENGER = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address constant MINTER = 0xb43db544E2c27092c107639Ad201b3dEfAbcF192;
    uint256 constant KEY_ONE = 0xA11CE;
    uint256 constant KEY_TWO = 0xB0B;
    uint256 constant AMOUNT = 1e6;
    uint256 constant BALANCE = 10_000e6;
    bytes32 constant MEMO_ID = keccak256("invoice:original:0");

    BridgeUsdcMock token;
    BridgeBookMock book;
    BridgeQuorumMock treasury;
    BridgeMessengerMock messenger;
    BridgeMinterMock minter;
    MemoConduit conduit;
    address recipient;

    function setUp() public {
        vm.chainId(SOURCE_CHAIN);
        vm.warp(1_780_000_000);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeUsdcMock", SOURCE_TOKEN);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeMinterMock", MINTER);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeMessengerMock", MESSENGER);
        token = BridgeUsdcMock(SOURCE_TOKEN);
        minter = BridgeMinterMock(MINTER);
        messenger = BridgeMessengerMock(MESSENGER);
        messenger.configure(MINTER);
        minter.setLimit(SOURCE_TOKEN, 1_000_000e6);
        book = new BridgeBookMock();
        treasury = new BridgeQuorumMock(vm.addr(KEY_ONE), vm.addr(KEY_TWO));
        address[] memory tokens = new address[](1);
        tokens[0] = SOURCE_TOKEN;
        conduit = new MemoConduit(IAddressBook(address(book)), tokens, MemoConduitCctpConfig.testnet());
        recipient = makeAddr("invoice destination");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        book.set(recipients);
        token.mint(address(treasury), BALANCE);
    }

    function payment() internal view returns (MemoConduit.BridgePayment memory) {
        return MemoConduit.BridgePayment({
            protocol: 1,
            token: SOURCE_TOKEN,
            from: address(treasury),
            recipient: recipient,
            amount: AMOUNT,
            destinationChainId: DESTINATION_CHAIN,
            destinationDomain: 26,
            destinationToken: DESTINATION_TOKEN,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("original source leg"),
            termsHash: keccak256("accepted immutable invoice terms"),
            memoId: MEMO_ID,
            memo: bytes("invoice:original:0"),
            tokenId: bytes32(0),
            quoteHash: bytes32(0),
            nativeFee: 0,
            quoteValidUntil: 0
        });
    }

    function signNonce(MemoConduit.BridgePayment memory p, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.from,
                address(conduit),
                p.amount,
                p.validAfter,
                p.validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY_ONE, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY_TWO, digest);
        return abi.encode(abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    function sign(MemoConduit.BridgePayment memory p) internal view returns (bytes memory) {
        return signNonce(p, conduit.bridgePaymentNonceOf(p));
    }

    function unchanged(MemoConduit.BridgePayment memory p) internal view {
        assertEq(token.balanceOf(address(treasury)), BALANCE);
        assertEq(token.balanceOf(address(conduit)), 0);
        assertEq(token.allowance(address(conduit), MESSENGER), 0);
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), bytes32(0));
        assertFalse(token.authorizationState(p.from, conduit.bridgePaymentNonceOf(p)));
        assertEq(messenger.calls(), 0);
    }

    function test_quorumAtomicBurnPreservesRecipientAmountNoCustody() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes32 nonce = conduit.bridgePaymentNonceOf(p);
        vm.prank(makeAddr("permissionless relay"));
        conduit.bridgeWithMemo(p, sign(p));
        assertEq(token.balanceOf(address(treasury)), BALANCE - AMOUNT);
        assertEq(token.balanceOf(address(conduit)), 0);
        assertEq(token.balanceOf(MINTER), 0);
        assertEq(token.totalSupply(), BALANCE - AMOUNT);
        assertEq(token.allowance(address(conduit), MESSENGER), 0);
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), nonce);
        assertTrue(token.authorizationState(p.from, nonce));
        assertEq(messenger.calls(), 1);
        assertEq(messenger.lastAmount(), AMOUNT);
        assertEq(messenger.lastDomain(), 26);
        assertEq(messenger.lastRecipient(), bytes32(uint256(uint160(recipient))));
        assertEq(messenger.lastToken(), SOURCE_TOKEN);
        assertEq(messenger.lastCaller(), bytes32(0));
        assertEq(messenger.lastFee(), 0);
        assertEq(messenger.lastFinality(), 2000);
        // Source burn is not final payment: recipient has not received any token here.
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_constructorRejectsHalfConfiguredCctp() public {
        address[] memory t = new address[](1);
        t[0] = SOURCE_TOKEN;
        CctpConfig memory c = MemoConduitCctpConfig.testnet();
        c.tokenMinter = address(0);
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        new MemoConduit(IAddressBook(address(book)), t, c);
        MemoConduit off = new MemoConduit(IAddressBook(address(book)), t, MemoConduitCctpConfig.none());
        assertEq(off.CCTP_TOKEN_MESSENGER(), address(0));
    }

    function test_notAllowlistedAndRevokedRecipientFailBeforeDebit() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        book.set(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, p.from, recipient));
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_unavailableAddressBookFailsClosed() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        book.setUnavailable(true);
        vm.expectRevert(bytes("book unavailable"));
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_oneSignerAndWrongQuorumRejectedByToken() public {
        MemoConduit.BridgePayment memory p = payment();
        (bytes memory one,) = abi.decode(sign(p), (bytes, bytes));
        bytes memory duplicateOne = abi.encode(one, one);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        conduit.bridgeWithMemo(p, duplicateOne);
        unchanged(p);
    }

    function test_changedAllowlistedRecipientCannotUseReviewedSignature() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        address[] memory recipients = new address[](2);
        recipients[0] = recipient;
        recipients[1] = makeAddr("another approved recipient");
        book.set(recipients);
        p.recipient = recipients[1];
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_eachReviewedBusinessFieldInvalidatesOriginalSignature() public {
        for (uint256 i; i < 8; ++i) {
            MemoConduit.BridgePayment memory p = payment();
            bytes memory sig = sign(p);
            if (i == 0) p.amount += 1;
            if (i == 1) p.validAfter -= 1;
            if (i == 2) p.validBefore += 1;
            if (i == 3) p.paymentId = keccak256("another source leg");
            if (i == 4) p.termsHash = keccak256("changed terms");
            if (i == 5) p.memoId = keccak256("another invoice");
            if (i == 6) p.memo = bytes("changed memo");
            if (i == 7) {
                p.destinationChainId = 43113;
                p.destinationDomain = 1;
                p.destinationToken = 0x5425890298aed601595a70AB815c96711a31Bc65;
            }
            vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
            conduit.bridgeWithMemo(p, sig);
            unchanged(p);
        }
    }

    function test_wrongSpenderAuthorizationCannotRedeem() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes32 nonce = conduit.bridgePaymentNonceOf(p);
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.from,
                MESSENGER, // signed to the messenger instead of this conduit
                p.amount,
                p.validAfter,
                p.validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY_ONE, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY_TWO, digest);
        bytes memory sig = abi.encode(abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_sameDocumentFreshWindowOrSourceLegStillCannotDuplicateBurn() public {
        MemoConduit.BridgePayment memory p = payment();
        conduit.bridgeWithMemo(p, sign(p));
        bytes32 committed = conduit.bridgePaymentCommitment(p.from, p.memoId);
        p.validBefore += 1;
        p.paymentId = keccak256("replacement attempt should not exist");
        bytes memory sig = sign(p);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, p.from, p.memoId));
        conduit.bridgeWithMemo(p, sig);
        assertEq(messenger.calls(), 1);
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), committed);
    }

    function test_uncertainSubmissionOriginalReplayNeverCreatesSecondBurn() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        conduit.bridgeWithMemo(p, sig);
        // A lost RPC response changes nothing; inspect the original commitment/nonce.
        assertEq(conduit.bridgePaymentCommitment(p.from, p.memoId), conduit.bridgePaymentNonceOf(p));
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, p.from, p.memoId));
        conduit.bridgeWithMemo(p, sig);
        assertEq(messenger.calls(), 1);
        assertEq(token.balanceOf(address(treasury)), BALANCE - AMOUNT);
    }

    function test_failedMessengerRestoresAuthorizationThenSameAttemptCanSucceed() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        messenger.setMode(1);
        vm.expectRevert(bytes("messenger unavailable"));
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
        messenger.setMode(0);
        conduit.bridgeWithMemo(p, sig);
        assertEq(messenger.calls(), 1);
    }

    function test_falseShortOrUnburnedTransferRevertsAllState() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        for (uint8 mode = 2; mode <= 5; ++mode) {
            messenger.setMode(mode);
            vm.expectRevert(MemoConduit.BridgeBurnMismatch.selector);
            conduit.bridgeWithMemo(p, sig);
            unchanged(p);
        }
    }

    function test_shortAuthorizationDebitRevertsBeforeBurn() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        token.setShortDebit(true);
        vm.expectRevert(MemoConduit.BridgeDebitMismatch.selector);
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_donationsCannotBeConsumedByAnotherDocument() public {
        token.mint(address(conduit), 7);
        MemoConduit.BridgePayment memory p = payment();
        conduit.bridgeWithMemo(p, sign(p));
        assertEq(token.balanceOf(address(conduit)), 7);
        assertEq(token.totalSupply(), BALANCE + 7 - AMOUNT);
    }

    function test_reentrantConcurrentRelayCannotBurnTwice() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        messenger.setCallback(address(conduit), abi.encodeCall(conduit.bridgeWithMemo, (p, sig)));
        conduit.bridgeWithMemo(p, sig);
        assertFalse(messenger.callbackSucceeded());
        assertEq(messenger.calls(), 1);
    }

    function test_routeDomainAndDestinationAssetMismatchBlockedBeforeDebit() public {
        MemoConduit.BridgePayment memory p = payment();
        for (uint256 i; i < 2; ++i) {
            if (i == 0) {
                p.destinationDomain = 1;
            } else {
                p.destinationDomain = 26;
                p.destinationToken = makeAddr("foreign USDC lookalike");
            }
            vm.expectRevert(MemoConduit.BridgeDestinationMismatch.selector);
            conduit.bridgeWithMemo(p, "");
            unchanged(p);
        }
    }

    function test_sourceLookalikeNativeAssetSameChainAndProductionBlocked() public {
        MemoConduit.BridgePayment memory p = payment();
        p.token = makeAddr("fake USDC");
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        p = payment();
        p.destinationChainId = SOURCE_CHAIN;
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        p = payment();
        p.destinationChainId = 5042;
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        vm.chainId(5042);
        p = payment();
        vm.expectPartialRevert(MemoConduit.BridgeRouteNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        unchanged(p);
    }

    function test_eurcAndCirbtcCannotEnterUsdcMessengerAsUnsupportedProtocols() public {
        MemoConduit.BridgePayment memory p = payment();
        for (uint8 protocol = 2; protocol <= 3; ++protocol) {
            p.protocol = protocol;
            vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, protocol));
            conduit.bridgeWithMemo(p, "");
            unchanged(p);
        }
    }

    function test_nonzeroFeeOrFastTransferBlockedBeforeDebit() public {
        MemoConduit.BridgePayment memory p = payment();
        p.maxFee = 1;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        p.maxFee = 0;
        p.minFinalityThreshold = 1000;
        vm.expectRevert(MemoConduit.BridgeFeeOrFinalityNotSupported.selector);
        conduit.bridgeWithMemo(p, "");
        unchanged(p);
    }

    function test_minterRegistrationAndRemoteMessengerRetirementFailClosed() public {
        MemoConduit.BridgePayment memory p = payment();
        for (uint256 i; i < 3; ++i) {
            messenger.configure(i == 0 ? makeAddr("unknown minter") : MINTER);
            messenger.setRemote(26, i == 1 ? bytes32(0) : bytes32(uint256(uint160(MESSENGER))));
            minter.setLimit(SOURCE_TOKEN, i == 2 ? AMOUNT - 1 : AMOUNT);
            vm.expectRevert(MemoConduit.BridgeDependencyMismatch.selector);
            conduit.bridgeWithMemo(p, "");
            unchanged(p);
        }
    }

    function test_expiredAuthorizationCannotDebitOrLeaveRefundableEscrow() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory sig = sign(p);
        vm.warp(p.validBefore);
        vm.expectRevert(MockUSDC3009.AuthExpired.selector);
        conduit.bridgeWithMemo(p, sig);
        unchanged(p);
    }

    function test_nonceBindsBothSourceChainAndConduit() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes32 nonce = conduit.bridgePaymentNonceOf(p);
        address[] memory tokens = new address[](1);
        tokens[0] = SOURCE_TOKEN;
        MemoConduit other = new MemoConduit(IAddressBook(address(book)), tokens, MemoConduitCctpConfig.testnet());
        assertNotEq(other.bridgePaymentNonceOf(p), nonce);
        vm.chainId(43113);
        assertNotEq(conduit.bridgePaymentNonceOf(p), nonce);
    }

    function test_legacyPaidMemoCannotStartBridge() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes memory bridgeSignature = sign(p);
        bytes32 legacyNonce = conduit.memoPaymentNonceOf(
            p.token, p.from, p.recipient, p.amount, p.validAfter, p.validBefore, p.memoId, p.memo
        );
        bytes memory legacySignature = signNonce(p, legacyNonce);
        conduit.payWithMemo(
            p.token, p.from, p.recipient, p.amount, p.validAfter, p.validBefore, p.memoId, p.memo, legacySignature
        );
        assertEq(conduit.memoPaymentCommitment(p.from, p.memoId), legacyNonce);
        vm.expectPartialRevert(MemoConduit.BridgeAlreadyDispatched.selector);
        conduit.bridgeWithMemo(p, bridgeSignature);
        assertEq(messenger.calls(), 0);
        assertEq(token.balanceOf(address(treasury)), BALANCE - AMOUNT);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_bridgeBurnedMemoCannotUseLegacyLocalPayment() public {
        MemoConduit.BridgePayment memory p = payment();
        bytes32 legacyNonce = conduit.memoPaymentNonceOf(
            p.token, p.from, p.recipient, p.amount, p.validAfter, p.validBefore, p.memoId, p.memo
        );
        bytes memory legacySignature = signNonce(p, legacyNonce);
        conduit.bridgeWithMemo(p, sign(p));
        vm.expectPartialRevert(MemoConduit.BridgeAlreadyDispatched.selector);
        conduit.payWithMemo(
            p.token, p.from, p.recipient, p.amount, p.validAfter, p.validBefore, p.memoId, p.memo, legacySignature
        );
        assertEq(messenger.calls(), 1);
        assertEq(token.balanceOf(address(treasury)), BALANCE - AMOUNT);
        assertEq(token.balanceOf(recipient), 0);
        assertFalse(token.authorizationState(p.from, legacyNonce));
    }

    function test_bridgeNonceMatchesIndependentDeskVector() public {
        address at = 0x1111111111111111111111111111111111111111;
        address[] memory tokens = new address[](1);
        tokens[0] = SOURCE_TOKEN;
        deployCodeTo("MemoConduit.sol:MemoConduit", abi.encode(address(book), tokens, MemoConduitCctpConfig.testnet()), at);
        vm.chainId(43113);
        MemoConduit.BridgePayment memory p = payment();
        p.token = 0x5425890298aed601595a70AB815c96711a31Bc65;
        p.from = 0x2222222222222222222222222222222222222222;
        p.recipient = 0x3333333333333333333333333333333333333333;
        p.amount = 1_000_000;
        p.validAfter = 0;
        p.validBefore = 1_800_000_000;
        p.paymentId = bytes32(uint256(0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc));
        p.termsHash = bytes32(uint256(0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb));
        p.memoId = bytes32(uint256(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa));
        p.memo = hex"1234";
        bytes32 nonce = MemoConduit(at).bridgePaymentNonceOf(p);
        assertEq(nonce, 0x98f69b2a774d1f69846d5fe22493fa17f2fb33c1917ea9546e25739400047163);
    }

    function testFuzz_exactAmountBurnAndReplay(uint96 rawAmount) public {
        MemoConduit.BridgePayment memory p = payment();
        p.amount = bound(uint256(rawAmount), 1, BALANCE);
        bytes memory sig = sign(p);
        conduit.bridgeWithMemo(p, sig);
        assertEq(token.balanceOf(address(treasury)), BALANCE - p.amount);
        assertEq(token.totalSupply(), BALANCE - p.amount);
        assertEq(token.balanceOf(address(conduit)), 0);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeAlreadyDispatched.selector, p.from, p.memoId));
        conduit.bridgeWithMemo(p, sig);
        assertEq(messenger.calls(), 1);
    }
}

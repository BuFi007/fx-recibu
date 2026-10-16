// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MemoConduit, IAddressBook} from "../../src/rails/MemoConduit.sol";
import {SpokeMemoConduit} from "../../src/rails/SpokeMemoConduit.sol";
import {MemoConduitCctpConfig} from "../../src/rails/MemoConduitCctpConfig.sol";
import {
    BridgeUsdcMock,
    BridgeBookMock,
    BridgeQuorumMock,
    BridgeMinterMock,
    BridgeMessengerMock
} from "./MemoConduitCctp.t.sol";

/// @notice SpokeMemoConduit on the testnet analogue (Fuji 43113 -> Arc testnet 5042002).
contract SpokeMemoConduitTest is Test {
    uint256 constant SPOKE = 43113;
    uint256 constant HUB = 5042002;
    address constant USDC = 0x5425890298aed601595a70AB815c96711a31Bc65; // Fuji USDC
    address constant HUB_USDC = 0x3600000000000000000000000000000000000000;
    address constant MESSENGER = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    address constant MINTER = 0xb43db544E2c27092c107639Ad201b3dEfAbcF192;
    uint256 constant KEY_ONE = 0xA11CE;
    uint256 constant KEY_TWO = 0xB0B;
    uint256 constant AMOUNT = 250e6;

    BridgeUsdcMock token;
    BridgeBookMock book;
    BridgeQuorumMock treasury;
    BridgeMessengerMock messenger;
    SpokeMemoConduit spoke;
    address recipient = makeAddr("hub repay adapter");

    function setUp() public {
        vm.chainId(SPOKE);
        vm.warp(1_780_000_000);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeUsdcMock", USDC);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeMinterMock", MINTER);
        deployCodeTo("MemoConduitCctp.t.sol:BridgeMessengerMock", MESSENGER);
        token = BridgeUsdcMock(USDC);
        messenger = BridgeMessengerMock(MESSENGER);
        messenger.configure(MINTER);
        BridgeMinterMock(MINTER).setLimit(USDC, 1_000_000e6);
        book = new BridgeBookMock();
        treasury = new BridgeQuorumMock(vm.addr(KEY_ONE), vm.addr(KEY_TWO));
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        spoke = new SpokeMemoConduit(IAddressBook(address(book)), tokens, MemoConduitCctpConfig.testnet());
        address[] memory r = new address[](1);
        r[0] = recipient;
        book.set(r);
        token.mint(address(treasury), 10_000e6);
    }

    function _payment() internal view returns (MemoConduit.BridgePayment memory) {
        return MemoConduit.BridgePayment({
            protocol: 1,
            token: USDC,
            from: address(treasury),
            recipient: recipient,
            amount: AMOUNT,
            destinationChainId: HUB,
            destinationDomain: 26,
            destinationToken: HUB_USDC,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("advance-42"),
            termsHash: keccak256("midnight-USDC/EURC-30d"),
            memoId: keccak256("invoice:42:0"),
            memo: bytes("invoice:42:0"),
            tokenId: bytes32(0),
            quoteHash: bytes32(0),
            nativeFee: 0,
            quoteValidUntil: 0
        });
    }

    function _sign(MemoConduit.BridgePayment memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.from,
                address(spoke),
                p.amount,
                p.validAfter,
                p.validBefore,
                spoke.bridgePaymentNonceOf(p)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY_ONE, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY_TWO, digest);
        return abi.encode(abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2));
    }

    function test_repayToHub_burnsAndEmitsRepaymentInitiated() public {
        MemoConduit.BridgePayment memory p = _payment();
        bytes32 nonce = spoke.bridgePaymentNonceOf(p);
        vm.expectEmit(true, true, true, true, address(spoke));
        emit SpokeMemoConduit.RepaymentInitiated(
            p.paymentId, p.termsHash, p.memoId, p.from, p.recipient, AMOUNT, 26, nonce, spoke.CCTP_MESSAGE_TRANSMITTER()
        );
        spoke.bridgeWithMemo(p, _sign(p));
        assertEq(messenger.calls(), 1);
        assertEq(messenger.lastDomain(), 26);
        assertEq(token.balanceOf(address(spoke)), 0);
        assertEq(spoke.bridgePaymentCommitment(p.from, p.memoId), nonce);
    }

    function test_onlySpokeToHub() public {
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, SPOKE, 84532));
        spoke.bridgeRouteOf(1, USDC, 84532);
        vm.chainId(HUB); // deployed on a hub it can never bridge
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, HUB, SPOKE));
        spoke.bridgeRouteOf(1, HUB_USDC, SPOKE);
    }

    function test_cctpxRefused() public {
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.BridgeProtocolNotSupported.selector, uint8(2)));
        spoke.bridgeRouteOf(2, USDC, HUB);
        MemoConduit.BridgePayment memory p = _payment();
        p.protocol = 2;
        vm.expectRevert();
        spoke.bridgeWithMemoCctpX(p, hex"01aa", "");
    }

    function test_wrongDestinationRevertsBeforeDebit() public {
        MemoConduit.BridgePayment memory p = _payment();
        p.destinationChainId = 84532;
        p.destinationDomain = 6;
        bytes memory sig = _sign(p);
        vm.expectRevert(abi.encodeWithSelector(SpokeMemoConduit.NotSpokeToHub.selector, SPOKE, 84532));
        spoke.bridgeWithMemo(p, sig);
        assertEq(token.balanceOf(address(treasury)), 10_000e6);
        assertEq(messenger.calls(), 0);
    }

    function test_checkoutConduitStaysBidirectionalAndSilent() public {
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        MemoConduit checkout = new MemoConduit(IAddressBook(address(book)), tokens, MemoConduitCctpConfig.testnet());
        (, uint32 d,,) = checkout.bridgeRouteOf(1, USDC, 84532); // spoke-only rule does not apply
        assertEq(d, 6);
        MemoConduit.BridgePayment memory p = _payment();
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.from,
                address(checkout),
                p.amount,
                p.validAfter,
                p.validBefore,
                checkout.bridgePaymentNonceOf(p)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY_ONE, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY_TWO, digest);
        vm.recordLogs();
        checkout.bridgeWithMemo(p, abi.encode(abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2)));
        bytes32 sig = SpokeMemoConduit.RepaymentInitiated.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != sig);
        }
    }
}

import {Vm} from "forge-std/Vm.sol";

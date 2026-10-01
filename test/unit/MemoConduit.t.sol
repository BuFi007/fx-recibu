// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MemoConduit, IAddressBook} from "../../src/rails/MemoConduit.sol";
import {IArcMemo} from "../../src/interfaces/IArcMemo.sol";
import {MockUSDC3009} from "../mocks/MockUSDC3009.sol";
import {MockArcUSDC, MockArcMemo, MockAddressBook, MockMultisigAccount} from "../mocks/MockArcMemoStack.sol";

/// @title MemoConduit unit tests — treasury (ERC-1271) pays a memo-tagged transfer atomically.
contract MemoConduitTest is Test {
    event Memo(
        address indexed sender,
        address indexed target,
        bytes32 callDataHash,
        bytes32 indexed memoId,
        bytes memo,
        uint256 memoIndex
    );

    MockArcUSDC usdc;
    MockArcUSDC eurc;
    MockArcMemo memo;
    MockAddressBook book;
    MemoConduit conduit;
    MockMultisigAccount treasury;

    uint256 signerKey = 0xA11CE;
    address recipient = makeAddr("biller-workspace");
    address stranger = makeAddr("not-allowlisted");
    address relayer = makeAddr("anyone");

    uint256 constant AMOUNT = 1_500e6;
    bytes32 constant MEMO_ID = keccak256("2f6c1b5e-0000-4000-8000-000000000001:0");
    bytes constant MEMO_DATA = "invoice:2f6c1b5e-0000-4000-8000-000000000001:0";
    uint256 validAfter;
    uint256 validBefore;

    function setUp() public {
        vm.warp(1_760_000_000);
        validAfter = block.timestamp - 1;
        validBefore = block.timestamp + 1 hours;

        usdc = new MockArcUSDC();
        eurc = new MockArcUSDC();
        memo = new MockArcMemo();
        usdc.setMemoForwarder(address(memo));
        eurc.setMemoForwarder(address(memo));
        book = new MockAddressBook();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        conduit = new MemoConduit(IArcMemo(address(memo)), IAddressBook(address(book)), tokens);

        treasury = new MockMultisigAccount(vm.addr(signerKey));
        usdc.mint(address(treasury), 10_000e6);
        eurc.mint(address(treasury), 10_000e6);
        book.add(address(treasury), recipient);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _nonce(address token, address to, uint256 amount, bytes32 memoId, bytes memory memoData)
        internal
        view
        returns (bytes32)
    {
        return
            conduit.memoPaymentNonceOf(token, address(treasury), to, amount, validAfter, validBefore, memoId, memoData);
    }

    /// The quorum signs a 3009 ReceiveWithAuthorization to the conduit with the derived nonce.
    function _sign(MockArcUSDC token, uint256 amount, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                address(treasury),
                address(conduit),
                amount,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signedFor(address to) internal view returns (bytes memory) {
        return _sign(usdc, AMOUNT, _nonce(address(usdc), to, AMOUNT, MEMO_ID, MEMO_DATA));
    }

    function _pay(address to, uint256 amount, bytes32 memoId, bytes memory memoData, bytes memory sig) internal {
        conduit.payWithMemo(
            address(usdc), address(treasury), to, amount, validAfter, validBefore, memoId, memoData, sig
        );
    }

    // ── happy path ───────────────────────────────────────────────────────────

    function test_anyoneSubmits_recipientPaid_memoEmitted_nothingHeld() public {
        bytes memory sig = _signedFor(recipient);

        vm.expectEmit(true, true, true, true, address(memo));
        emit Memo(
            address(conduit),
            address(usdc),
            keccak256(abi.encodeCall(IERC20.transfer, (recipient, AMOUNT))),
            MEMO_ID,
            MEMO_DATA,
            0
        );
        vm.prank(relayer);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);

        assertEq(usdc.balanceOf(recipient), AMOUNT);
        assertEq(usdc.balanceOf(address(treasury)), 10_000e6 - AMOUNT);
        assertEq(usdc.balanceOf(address(conduit)), 0);
        assertTrue(
            usdc.authorizationState(address(treasury), _nonce(address(usdc), recipient, AMOUNT, MEMO_ID, MEMO_DATA))
        );
    }

    function test_dustOnConduitIsIgnoredNotSwept() public {
        usdc.mint(address(conduit), 7);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, _signedFor(recipient));
        assertEq(usdc.balanceOf(address(conduit)), 7);
        assertEq(usdc.balanceOf(recipient), AMOUNT);
    }

    // ── the signature commits to every field ─────────────────────────────────

    function test_revert_recipientSwapped() public {
        book.add(address(treasury), stranger); // even an allowlisted second recipient
        bytes memory sig = _signedFor(recipient);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(stranger, AMOUNT, MEMO_ID, MEMO_DATA, sig);
    }

    function test_revert_amountChanged() public {
        bytes memory sig = _signedFor(recipient);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(recipient, AMOUNT - 1, MEMO_ID, MEMO_DATA, sig);
    }

    function test_revert_memoIdChanged() public {
        bytes memory sig = _signedFor(recipient);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(recipient, AMOUNT, keccak256("other-invoice:0"), MEMO_DATA, sig);
    }

    function test_revert_memoDataChanged() public {
        bytes memory sig = _signedFor(recipient);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(recipient, AMOUNT, MEMO_ID, bytes("reimbursement:other:0"), sig);
    }

    function test_revert_windowChanged() public {
        bytes memory sig = _signedFor(recipient);
        validBefore += 1;
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);
    }

    function test_revert_wrongSigner() public {
        bytes32 nonce = _nonce(address(usdc), recipient, AMOUNT, MEMO_ID, MEMO_DATA);
        signerKey = 0xB0B;
        bytes memory sig = _sign(usdc, AMOUNT, nonce);
        vm.expectRevert(MockUSDC3009.InvalidSignature.selector);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);
    }

    function test_revert_replay() public {
        bytes memory sig = _signedFor(recipient);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);
        vm.expectRevert(MockUSDC3009.AuthUsed.selector);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);
    }

    function test_revert_expired() public {
        bytes memory sig = _signedFor(recipient);
        vm.warp(validBefore);
        vm.expectRevert(MockUSDC3009.AuthExpired.selector);
        _pay(recipient, AMOUNT, MEMO_ID, MEMO_DATA, sig);
    }

    // ── allowlist + token gates ──────────────────────────────────────────────

    function test_revert_recipientNotAllowlisted() public {
        bytes memory sig = _sign(usdc, AMOUNT, _nonce(address(usdc), stranger, AMOUNT, MEMO_ID, MEMO_DATA));
        vm.expectRevert(
            abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, address(treasury), stranger)
        );
        _pay(stranger, AMOUNT, MEMO_ID, MEMO_DATA, sig);
        assertEq(usdc.balanceOf(address(treasury)), 10_000e6);
    }

    function test_revert_payerWithoutAddressBook() public {
        MockMultisigAccount bare = new MockMultisigAccount(vm.addr(signerKey));
        usdc.mint(address(bare), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.RecipientNotAllowlisted.selector, address(bare), recipient));
        conduit.payWithMemo(
            address(usdc), address(bare), recipient, AMOUNT, validAfter, validBefore, MEMO_ID, MEMO_DATA, ""
        );
    }

    function test_revert_unsupportedToken() public {
        bytes memory sig = _sign(eurc, AMOUNT, _nonce(address(eurc), recipient, AMOUNT, MEMO_ID, MEMO_DATA));
        vm.expectRevert(abi.encodeWithSelector(MemoConduit.TokenNotSupported.selector, address(eurc)));
        conduit.payWithMemo(
            address(eurc), address(treasury), recipient, AMOUNT, validAfter, validBefore, MEMO_ID, MEMO_DATA, sig
        );
    }

    function test_secondTokenWhenListedAtDeploy() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(eurc);
        conduit = new MemoConduit(IArcMemo(address(memo)), IAddressBook(address(book)), tokens);
        bytes memory sig = _sign(eurc, AMOUNT, _nonce(address(eurc), recipient, AMOUNT, MEMO_ID, MEMO_DATA));
        conduit.payWithMemo(
            address(eurc), address(treasury), recipient, AMOUNT, validAfter, validBefore, MEMO_ID, MEMO_DATA, sig
        );
        assertEq(eurc.balanceOf(recipient), AMOUNT);
    }

    function test_revert_zeroAmountAndRecipient() public {
        vm.expectRevert(MemoConduit.ZeroAmount.selector);
        _pay(recipient, 0, MEMO_ID, MEMO_DATA, "");
        vm.expectRevert(MemoConduit.ZeroAddress.selector);
        _pay(address(0), AMOUNT, MEMO_ID, MEMO_DATA, "");
    }

    // ── nonce is chain- and conduit-bound ────────────────────────────────────

    function test_nonceBindsChainAndConduit() public {
        bytes32 here = _nonce(address(usdc), recipient, AMOUNT, MEMO_ID, MEMO_DATA);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        MemoConduit other = new MemoConduit(IArcMemo(address(memo)), IAddressBook(address(book)), tokens);
        assertTrue(
            here
                != other.memoPaymentNonceOf(
                    address(usdc), address(treasury), recipient, AMOUNT, validAfter, validBefore, MEMO_ID, MEMO_DATA
                )
        );
        vm.chainId(block.chainid + 1);
        assertTrue(here != _nonce(address(usdc), recipient, AMOUNT, MEMO_ID, MEMO_DATA));
    }
}

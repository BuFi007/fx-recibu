// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArcMemo} from "../interfaces/IArcMemo.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";

/// @notice Circle ColdStorageAddressBookPlugin read surface (same address on every chain).
interface IAddressBook {
    function getAllowedRecipients(address account) external view returns (address[] memory);
}

/// @title MemoConduit — one signed authorization, one memo-tagged payment, one transaction.
///
/// A treasury MSCA cannot call the Arc Memo predeploy itself: its ColdStorageAddressBook
/// rejects any non-transfer selector. Instead the treasury quorum signs an ERC-3009
/// `ReceiveWithAuthorization` to THIS contract, and anyone submits {payWithMemo}:
///   1. the recipient must be on the payer's on-chain allowlist (fail closed),
///   2. the 3009 nonce is DERIVED here from (token, from, recipient, amount, window, memoId,
///      memoData), so the quorum signature commits to the whole payment and the document,
///   3. `receiveWithAuthorization` pulls the funds (bytes overload: ERC-1271 for the MSCA),
///   4. the Arc Memo predeploy forwards `transfer(recipient, amount)` with this contract as
///      sender and emits the `Memo` event desk's webhook already verifies,
///   5. the contract must end holding exactly what it held before.
/// Any failure reverts everything; the nonce stays unused. No owner, no setter, no storage
/// written: the token set is fixed at deploy.
///
/// Sibling of {RecibuMemoRouter} (same deterministic-nonce binding) for plain invoices and
/// reimbursements, which are not on the factoring shelf.
contract MemoConduit is ReentrancyGuard {
    bytes32 public constant MEMO_PAYMENT_NONCE_TYPEHASH = keccak256(
        "MemoConduitPayment(uint256 chainId,address conduit,address token,address from,address recipient,uint256 amount,uint256 validAfter,uint256 validBefore,bytes32 memoId,bytes32 memoDataHash)"
    );

    IArcMemo public immutable MEMO;
    IAddressBook public immutable ADDRESS_BOOK;
    mapping(address => bool) public supportedToken;

    event MemoConduitPayment(
        bytes32 indexed memoId, address indexed from, address indexed recipient, address token, uint256 amount
    );

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported(address token);
    error RecipientNotAllowlisted(address from, address recipient);
    error BalanceChanged(uint256 before, uint256 afterPayment);

    constructor(IArcMemo memo_, IAddressBook addressBook_, address[] memory tokens) {
        if (address(memo_) == address(0) || address(addressBook_) == address(0)) revert ZeroAddress();
        MEMO = memo_;
        ADDRESS_BOOK = addressBook_;
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
        if (!_isAllowlisted(from, recipient)) revert RecipientNotAllowlisted(from, recipient);

        bytes32 nonce = memoPaymentNonceOf(token, from, recipient, amount, validAfter, validBefore, memoId, memoData);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        IERC3009(token).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, signature);
        MEMO.memo(token, abi.encodeCall(IERC20.transfer, (recipient, amount)), memoId, memoData);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert BalanceChanged(balanceBefore, balanceAfter);

        emit MemoConduitPayment(memoId, from, recipient, token, amount);
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

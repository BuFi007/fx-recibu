// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MockUSDC3009} from "./MockUSDC3009.sol";

/// @title MockArcUSDC — MockUSDC3009 + the FiatToken v2.2 `bytes signature` overload (ERC-1271)
///        + a hook the mock Memo predeploy uses to emulate Arc's sender-preserving forwarding.
contract MockArcUSDC is MockUSDC3009 {
    address public memoForwarder;

    function setMemoForwarder(address forwarder) external {
        memoForwarder = forwarder;
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
        if (msg.sender != to) revert CallerNotPayee();
        if (block.timestamp <= validAfter) revert AuthNotYetValid();
        if (block.timestamp >= validBefore) revert AuthExpired();
        if (authorizationState[from][nonce]) revert AuthUsed();
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    /// @dev Arc's predeploy makes the inner call with the ORIGINAL caller as sender.
    function forwardTransfer(address sender, address to, uint256 value) external returns (bool) {
        require(msg.sender == memoForwarder, "not memo");
        _transfer(sender, to, value);
        return true;
    }
}

/// @title MockArcMemo — emulates the Arc Memo predeploy for `transfer` inner calls.
contract MockArcMemo {
    event Memo(
        address indexed sender,
        address indexed target,
        bytes32 callDataHash,
        bytes32 indexed memoId,
        bytes memo,
        uint256 memoIndex
    );

    uint256 public memoIndex;

    function memo(address target, bytes calldata data, bytes32 memoId, bytes calldata memoData) external {
        require(bytes4(data[:4]) == bytes4(keccak256("transfer(address,uint256)")), "only transfer");
        (address to, uint256 value) = abi.decode(data[4:], (address, uint256));
        MockArcUSDC(target).forwardTransfer(msg.sender, to, value);
        emit Memo(msg.sender, target, keccak256(data), memoId, memoData, memoIndex++);
    }
}

/// @title MockAddressBook — per-account recipient allowlist with the plugin's read shape.
contract MockAddressBook {
    mapping(address => address[]) internal allowed;

    function add(address account, address recipient) external {
        allowed[account].push(recipient);
    }

    function getAllowedRecipients(address account) external view returns (address[] memory) {
        return allowed[account];
    }
}

/// @title MockMultisigAccount — ERC-1271 smart account standing in for the treasury MSCA.
contract MockMultisigAccount is IERC1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

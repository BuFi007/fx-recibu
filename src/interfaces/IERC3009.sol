// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IERC3009 — Transfer With Authorization (Circle FiatToken; USDC/EURC native).
/// @notice Signature-based, gasless, replay-protected token movement. A payer signs an
///         off-chain authorization; any relayer submits it. `receiveWithAuthorization`
///         binds the submitter to `to` (front-run-safe) — the memo router uses only this
///         variant. Replay-protected by `nonce`; time-boxed by validAfter/validBefore.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice FiatToken v2.2 overload: `signature` is validated with ERC-1271 when `from` is a
    ///         contract (smart-account / multisig payers), else as a packed ECDSA signature.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

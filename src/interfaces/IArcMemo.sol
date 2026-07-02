// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IArcMemo — Arc `Memo` predeploy interface (0x5294E9927c3306DcBaDb03fe70b92e01cCede505)
/// @notice Forwards an inner call (e.g. USDC.transfer) preserving the caller as sender and
///         emits an indexed Memo event. Hand-declared; see docs/LICENSE_BOUNDARIES.md.
///         Ref: docs.arc.io/arc/tutorials/send-usdc-with-transaction-memo
interface IArcMemo {
    event Memo(
        address indexed sender,
        address indexed target,
        bytes32 callDataHash,
        bytes32 indexed memoId,
        bytes memo,
        uint256 memoIndex
    );

    function memo(address target, bytes calldata data, bytes32 memoId, bytes calldata memoData) external;
}

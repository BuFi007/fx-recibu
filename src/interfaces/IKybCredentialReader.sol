// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IKybCredentialReader
/// @notice Minimal read boundary consumed by the ACE KYB policy.
///         Implementations must return false for unknown, revoked, or expired
///         team credentials and must not expose PII.
interface IKybCredentialReader {
    function teamKybApproved(bytes32 teamKey) external view returns (bool);
}

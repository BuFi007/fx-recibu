// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IKybCredentialReader} from "../interfaces/IKybCredentialReader.sol";

/// @dev Local ABI-compatible declarations for Chainlink ACE policy contracts.
///      fx-recibu intentionally keeps ACE as an optional deployment dependency;
///      the selectors and enum encoding match IPolicy/IPolicyEngine exactly.
interface IKybPolicyEngine {
    enum PolicyResult {
        None,
        Allowed,
        Continue
    }

    error PolicyRejected(string rejectReason);
}

interface IKybPolicy is IERC165 {
    function typeAndVersion() external pure returns (string memory);
    function onInstall(address subject, bytes4 selector) external;
    function onUninstall(address subject, bytes4 selector) external;
    function run(address caller, address subject, bytes4 selector, bytes[] calldata parameters, bytes calldata context)
        external
        view
        returns (IKybPolicyEngine.PolicyResult);
    function postRun(
        address caller,
        address subject,
        bytes4 selector,
        bytes[] calldata parameters,
        bytes calldata context
    ) external;
}

/// @title KybWorkspacePolicy
/// @notice ACE-compatible hard gate for team-keyed KYB credentials.
///
/// The policy receives one or more ABI-encoded bytes32 team keys from the ACE
/// extractor/mapper. An unknown, revoked, expired, or unavailable credential
/// rejects with PolicyRejected("KYB"). Approved credentials return Continue so
/// later policies (limits, sanctions, pause) still run.
contract KybWorkspacePolicy is IKybPolicy {
    string public constant override typeAndVersion = "KybWorkspacePolicy 1.0.0";
    bytes32 public constant TEAM_ID_PARAMETER = keccak256("teamId");

    IKybCredentialReader public immutable CREDENTIALS;

    error ZeroAddress();
    error InvalidParameters();

    constructor(IKybCredentialReader credentials) {
        if (address(credentials) == address(0)) revert ZeroAddress();
        CREDENTIALS = credentials;
    }

    /// @notice Returns whether a team currently holds a non-expired credential.
    ///         Useful for off-chain preflight; ACE calls run() for enforcement.
    function checkTeam(bytes32 teamKey) public view returns (bool) {
        if (teamKey == bytes32(0)) return false;
        try CREDENTIALS.teamKybApproved(teamKey) returns (bool approved) {
            return approved;
        } catch {
            return false;
        }
    }

    function run(address, address, bytes4, bytes[] calldata parameters, bytes calldata)
        external
        view
        override
        returns (IKybPolicyEngine.PolicyResult)
    {
        if (parameters.length == 0) revert InvalidParameters();

        for (uint256 i = 0; i < parameters.length; ++i) {
            bytes32 teamKey = abi.decode(parameters[i], (bytes32));
            if (!checkTeam(teamKey)) revert IKybPolicyEngine.PolicyRejected("KYB");
        }

        // Continue instead of Allowed: policy ordering must still permit
        // sanctions, pause, and amount-limit policies to execute.
        return IKybPolicyEngine.PolicyResult.Continue;
    }

    /// @dev ACE calls these hooks during policy lifecycle management. This
    /// policy has immutable configuration, so both hooks are intentionally no-op.
    function onInstall(address, bytes4) external override {}
    function onUninstall(address, bytes4) external override {}
    function postRun(address, address, bytes4, bytes[] calldata, bytes calldata) external override {}

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IKybPolicy).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

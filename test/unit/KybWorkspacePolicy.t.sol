// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KybWorkspacePolicy, IKybPolicyEngine} from "../../src/identity/KybWorkspacePolicy.sol";
import {IKybCredentialReader} from "../../src/interfaces/IKybCredentialReader.sol";

contract MockKybCredentialReader is IKybCredentialReader {
    mapping(bytes32 => bool) internal approved;

    function setApproved(bytes32 teamKey, bool value) external {
        approved[teamKey] = value;
    }

    function teamKybApproved(bytes32 teamKey) external view returns (bool) {
        return approved[teamKey];
    }
}

contract KybWorkspacePolicyTest is Test {
    MockKybCredentialReader internal credentials;
    KybWorkspacePolicy internal policy;
    bytes32 internal approvedTeam = keccak256("approved-team");
    bytes32 internal rejectedTeam = keccak256("rejected-team");

    function setUp() public {
        credentials = new MockKybCredentialReader();
        policy = new KybWorkspacePolicy(credentials);
        credentials.setApproved(approvedTeam, true);
    }

    function test_approvedTeamContinuesPolicyChain() public view {
        bytes[] memory parameters = new bytes[](1);
        parameters[0] = abi.encode(approvedTeam);

        IKybPolicyEngine.PolicyResult result = policy.run(address(this), address(1), bytes4(0), parameters, "");
        assertEq(uint8(result), uint8(IKybPolicyEngine.PolicyResult.Continue));
        assertTrue(policy.checkTeam(approvedTeam));
    }

    function test_rejectedTeamRevertsKYB() public {
        bytes[] memory parameters = new bytes[](1);
        parameters[0] = abi.encode(rejectedTeam);

        vm.expectRevert(abi.encodeWithSelector(IKybPolicyEngine.PolicyRejected.selector, "KYB"));
        policy.run(address(this), address(1), bytes4(0), parameters, "");
    }

    function test_explicitRevocationIsRejected() public {
        credentials.setApproved(approvedTeam, false);
        bytes[] memory parameters = new bytes[](1);
        parameters[0] = abi.encode(approvedTeam);

        vm.expectRevert(abi.encodeWithSelector(IKybPolicyEngine.PolicyRejected.selector, "KYB"));
        policy.run(address(this), address(1), bytes4(0), parameters, "");
    }

    function test_zeroTeamKeyAndEmptyParametersFailClosed() public {
        vm.expectRevert(KybWorkspacePolicy.InvalidParameters.selector);
        policy.run(address(this), address(1), bytes4(0), new bytes[](0), "");

        bytes[] memory parameters = new bytes[](1);
        parameters[0] = abi.encode(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IKybPolicyEngine.PolicyRejected.selector, "KYB"));
        policy.run(address(this), address(1), bytes4(0), parameters, "");
    }
}

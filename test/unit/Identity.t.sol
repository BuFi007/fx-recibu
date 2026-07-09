// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BUFIIdentityRegistry} from "../../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../../src/identity/BUFIReputationRegistry.sol";
import {IBUFIIdentityRegistry} from "../../src/interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../../src/interfaces/IBUFIReputationRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract IdentityTest is Test {
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal attestor = makeAddr("attestor");
    address internal settlement = makeAddr("settlement");
    address internal ops = makeAddr("ops");
    address internal rando = makeAddr("rando");
    address internal wsOwner = makeAddr("wsOwner");

    bytes32 internal constant WS = keccak256("workspace-1");

    function setUp() public {
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), issuer);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), attestor);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), settlement);
        reputation.grantRole(reputation.OPS_ROLE(), ops);
        vm.stopPrank();
    }

    function _register() internal returns (uint256 agentId) {
        vm.prank(issuer);
        agentId = identity.registerWorkspace(WS, wsOwner);
    }

    // ── identity ──

    function test_register_assignsSequentialIdsAndState() public {
        uint256 id1 = _register();
        vm.prank(issuer);
        uint256 id2 = identity.registerWorkspace(keccak256("workspace-2"), wsOwner);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(identity.agentIdOf(WS), id1);
        assertEq(identity.workspaceOf(id1), WS);
        assertEq(identity.ownerOf(id1), wsOwner);
        assertTrue(identity.exists(id1));
        assertFalse(identity.kybApproved(id1)); // KYB never defaults to approved
    }

    function test_register_revertsOnDuplicateAndUnauthorized() public {
        _register();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(BUFIIdentityRegistry.AlreadyRegistered.selector, WS));
        identity.registerWorkspace(WS, wsOwner);

        vm.prank(rando);
        vm.expectRevert();
        identity.registerWorkspace(keccak256("x"), wsOwner);
    }

    function test_kybFlag_onlyIssuer() public {
        uint256 id = _register();
        vm.prank(issuer);
        identity.setKybStatus(id, true);
        assertTrue(identity.kybApproved(id));

        vm.prank(rando);
        vm.expectRevert();
        identity.setKybStatus(id, false);
    }

    function test_kybCredentialExpiresAndVersions() public {
        uint256 id = _register();
        vm.prank(issuer);
        identity.setKybStatus(id, true, uint64(block.timestamp + 10), 1, bytes32("op1"));
        assertTrue(identity.kybApproved(id));
        vm.warp(block.timestamp + 11);
        assertFalse(identity.kybApproved(id));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(BUFIIdentityRegistry.StaleKybVersion.selector, 1, 1));
        identity.setKybStatus(id, false, 0, 1, bytes32("op1"));
    }

    // ── reputation write-path law ──

    function test_setScore_onlyAttestor_andRangeChecked() public {
        uint256 id = _register();
        vm.prank(attestor);
        reputation.setScore(id, 74, 87, 1, bytes32("root"));
        IBUFIReputationRegistry.ScoreSnapshot memory s = reputation.scoreOf(id);
        assertEq(s.sellerScore, 74);
        assertEq(s.debtorScore, 87);
        assertEq(s.modelVersion, 1);

        vm.prank(attestor);
        vm.expectRevert(BUFIReputationRegistry.ScoreOutOfRange.selector);
        reputation.setScore(id, 101, 50, 1, bytes32(0));

        vm.prank(settlement); // settlement may NOT write scores
        vm.expectRevert();
        reputation.setScore(id, 10, 10, 1, bytes32(0));
    }

    function test_paidOnTime_onlySettlement_andMonotonic() public {
        uint256 id = _register();
        vm.prank(settlement);
        reputation.recordOnTimeInstallment(id);
        vm.prank(settlement);
        reputation.recordOnTimeInstallment(id);
        assertEq(reputation.paidOnTimeCumulative(id), 2);

        vm.prank(attestor); // attestor may NOT touch realized repayment
        vm.expectRevert();
        reputation.recordOnTimeInstallment(id);
    }

    function test_permanentDefault_isTerminal() public {
        uint256 id = _register();
        vm.prank(ops);
        reputation.setPermanentDefault(id);
        assertTrue(reputation.permanentDefault(id));

        // no writes on a dead identity
        vm.prank(attestor);
        vm.expectRevert(abi.encodeWithSelector(BUFIReputationRegistry.AgentPermanentlyDefaulted.selector, id));
        reputation.setScore(id, 90, 90, 2, bytes32(0));
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(BUFIReputationRegistry.AgentPermanentlyDefaulted.selector, id));
        reputation.recordOnTimeInstallment(id);

        vm.prank(rando);
        vm.expectRevert();
        reputation.setPermanentDefault(id);
    }

    function test_pairSettlement_recordsBothDirectionsIndependently() public {
        uint256 seller = _register();
        vm.prank(issuer);
        uint256 debtor = identity.registerWorkspace(keccak256("debtor"), wsOwner);

        vm.prank(settlement);
        reputation.recordPairSettlement(seller, debtor);
        assertEq(reputation.pairSettledCount(seller, debtor), 1);
        assertEq(reputation.pairSettledCount(debtor, seller), 0); // directional
    }
}
